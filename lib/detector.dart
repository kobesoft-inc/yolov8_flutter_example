import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class Detector {
  DetectorListener listener;
  double confidenceThreshold;
  late List<String> _labels;
  late Interpreter _interpreter;
  late IsolateInterpreter _isolateInterpreter;
  int tensorWidth = 0;
  int tensorHeight = 0;
  int numChannels = 0;
  int numElements = 0;

  Detector({
    required String modelPath,
    required String labelsPath,
    required this.listener,
    this.confidenceThreshold = 0.2,
  }) {
    _initialize(modelPath, labelsPath);
  }

  Future<void> _initialize(String modelPath, String labelsPath) async {
    // モデルを読み込んで、推論の準備を行う
    _interpreter = await Interpreter.fromAsset(modelPath,
        options: _getInterpreterOptions());
    _isolateInterpreter =
    await IsolateInterpreter.create(address: _interpreter.address);

    // モデルの入力の形状を取得
    final inputShape = _interpreter.getInputTensor(0).shape;
    tensorWidth = inputShape[1];
    tensorHeight = inputShape[2];
    if (inputShape[1] == 3) {
      tensorWidth = inputShape[2];
      tensorHeight = inputShape[3];
    }

    // モデルの出力の形状を取得
    final outputShape = _interpreter.getOutputTensor(0).shape;
    numChannels = outputShape[1];
    numElements = outputShape[2];

    // ラベルを読み込む
    final labels = await rootBundle.loadString(labelsPath);
    _labels = labels.split('\n');
  }

  /// 推論のオプションを取得
  InterpreterOptions _getInterpreterOptions() {
    var options = InterpreterOptions();
    if (Platform.isIOS) {
      options.addDelegate(GpuDelegate(options: GpuDelegateOptions()));
    } else if (Platform.isAndroid) {
      options.addDelegate(GpuDelegateV2(options: GpuDelegateOptionsV2()));
    } else {
      options.threads = 4;
    }
    return options;
  }

  void close() {
    _interpreter.close();
    _isolateInterpreter.close();
  }

  Future<void> detectWithCameraImage(CameraImage cameraImage) async {
    // 入出力サイズが0の場合は初期化が完了していないので終了
    if (isInitialized()) {
      return;
    }

    // カメラ画像を画像に変換
    return detect(_cameraImageToImage(cameraImage));
  }

  Future<void> detectWithImageProvider(ImageProvider imageProvider) async {
    // 入出力サイズが0の場合は初期化が完了していないので終了
    if (isInitialized()) {
      return;
    }

    // カメラ画像を画像に変換
    return detect(await _imageProviderToImage(imageProvider));
  }

  bool isInitialized() {
    return tensorWidth == 0 ||
        tensorHeight == 0 ||
        numChannels == 0 ||
        numElements == 0;
  }

  Future<void> detect(img.Image image) async {
    // 画像をリサイズ
    final cmd = (Command()
      ..image(image)
      ..copyResize(
        width: tensorWidth,
        height: tensorHeight,
        interpolation: Interpolation.nearest,
      ));
    var resizedImage = await cmd.getImageThread();

    // 画像を入力テンソルに変換
    var input = _imageToTensor(resizedImage!);

    // 出力テンソルを作成
    var output = Float32List(numChannels * numElements);

    // 推論を行う
    await _isolateInterpreter.run(input.buffer, output.buffer);

    // テンソルを結果に変換
    var result = _tensorToResults(output);

    // 結果を通知
    listener.onDetect(result);
  }

  /// カメラ画像を画像に変換
  img.Image _cameraImageToImage(CameraImage cameraImage) {
    return img.Image.fromBytes(
      width: cameraImage.width,
      height: cameraImage.height,
      bytes: cameraImage.planes[0].bytes.buffer,
      format: img.Format.uint8,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
  }

  /// ImageProviderを画像に変換
  Future<img.Image> _imageProviderToImage(ImageProvider imageProvider) async {
    // 1. ImageProvider から ImageStream を取得
    final ImageStream imageStream = imageProvider.resolve(ImageConfiguration());
    final Completer<ui.Image> completer = Completer<ui.Image>();

    // 2. ImageStreamListener で画像がロードされるのを待つ
    final listener =
    ImageStreamListener((ImageInfo imageInfo, bool synchronousCall) {
      completer.complete(imageInfo.image);
    });

    imageStream.addListener(listener);

    // 3. ui.Image を取得
    final ui.Image image = await completer.future;
    imageStream.removeListener(listener); // リスナーを削除

    // 4. ピクセルデータを取得 (format: RGBA)
    final ByteData? byteData =
    await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final Uint8List pixels = byteData!.buffer.asUint8List();

    // 5. ImageをImage.Imageに変換
    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: pixels.buffer,
      format: img.Format.uint8,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  /// 画像をテンソルに変換
  ///
  /// 画像のピクセル値を0.0〜1.0の範囲に正規化してテンソルに変換します。
  /// テンソルの値はBRGの順に並んでいます。
  Float32List _imageToTensor(img.Image image) {
    var tensor = Float32List(image.width * image.height * 3);
    var i = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        var pixel = image.getPixel(x, y);
        tensor[i++] = pixel.b / 255.0;
        tensor[i++] = pixel.r / 255.0;
        tensor[i++] = pixel.g / 255.0;
      }
    }
    return tensor;
  }

  /// テンソルを結果に変換
  ///
  /// テンソルから検出結果を取得します。
  /// テンソルの値は以下のように並んでいます。
  /// [
  ///   cx...(numElements),
  ///   cy...(numElements),
  ///   width...(numElements),
  ///   height...(numElements),
  ///   class1-confidence...(numElements),
  ///   class2-confidence...(numElements),
  ///   ...
  /// ]
  DetectionList _tensorToResults(Float32List t) {
    var results = <Detection>[];
    for (var e = 0; e < numElements; e++) {
      // 最も確信度の高いクラスを取得
      var maxClass = -1;
      var maxConfidence = confidenceThreshold;
      for (var c = 0; c < numChannels - 4; c++) {
        var confidence = _getConfidenceFromTensor(t, e, c);
        if (confidence > maxConfidence) {
          maxClass = c;
          maxConfidence = confidence;
        }
      }

      // 確信度が閾値を超えていない場合はスキップ
      if (maxClass == -1) {
        continue;
      }

      // 検出結果を追加
      final rect = _getRectFromTensor(t, e);
      if (rect.left < 0 || rect.right > 1 || rect.top < 0 || rect.bottom > 1) {
        // 画像の範囲外の場合はスキップ
        continue;
      }
      results.add(Detection(
        label: _labels[maxClass],
        labelId: maxClass,
        confidence: maxConfidence,
        rect: rect,
      ));
    }
    return DetectionList(detections: results);
  }

  /// テンソルから指定したクラスの信頼度を取得
  ///
  /// @param t テンソル
  /// @param e 要素のインデックス
  /// @param c クラスのインデックス
  double _getConfidenceFromTensor(Float32List t, int e, int c) {
    return t[e + (c + 4) * numElements];
  }

  /// テンソルから中心座標を取得
  ///
  /// @param t テンソル
  /// @param e 要素のインデックス
  Rect _getRectFromTensor(Float32List t, int e) {
    return Rect.fromCenter(
        center: Offset(
          t[e],
          t[e + numElements],
        ),
        width: t[e + 2 * numElements],
        height: t[e + 3 * numElements]);
  }
}

class Detection {
  final String label;
  final int labelId;
  final double confidence;
  final Rect rect;

  Detection({
    required this.label,
    required this.labelId,
    required this.confidence,
    required this.rect,
  });

  Rect scaledRect(double width, double height) {
    return Rect.fromLTRB(
      rect.left * width,
      rect.top * height,
      rect.right * width,
      rect.bottom * height,
    );
  }
}

class DetectionList {
  final List<Detection> detections;

  DetectionList({this.detections = const []});

  /// 信頼度でフィルタリング
  DetectionList filterByConfidence(double minConfidence) {
    return DetectionList(
      detections:
      detections.where((d) => d.confidence >= minConfidence).toList(),
    );
  }

  /// クラスでフィルタリング
  DetectionList filterByClass(String label) {
    return DetectionList(
      detections: detections.where((d) => d.label == label).toList(),
    );
  }

  /// 指定された矩形内に含まれる検出をフィルタリング
  DetectionList filterByRect(Rect rect) {
    return DetectionList(
      detections: detections.where((d) => d.rect.overlaps(rect)).toList(),
    );
  }

  /// 縦横の比率が指定された範囲内に含まれる検出をフィルタリング
  DetectionList filterByAspectRatio(double minAspectRatio, double maxAspectRatio) {
    return DetectionList(
      detections: detections.where((d) {
        var aspectRatio = d.rect.width / d.rect.height;
        return aspectRatio >= minAspectRatio && aspectRatio <= maxAspectRatio;
      }).toList(),
    );
  }

  /// 最も確信度の高い検出を取得
  Detection? getHighestConfidenceDetection() {
    if (detections.isEmpty) return null;
    return detections.reduce((a, b) => a.confidence > b.confidence ? a : b);
  }

  /// 最も位置が低い検出を取得
  Detection? getLowestPositionDetection() {
    if (detections.isEmpty) return null;
    return detections.reduce((a, b) => a.rect.top > b.rect.top ? a : b);
  }

  /// 最も位置が高い検出を取得
  Detection? getHighestPositionDetection() {
    if (detections.isEmpty) return null;
    return detections.reduce((a, b) => a.rect.bottom < b.rect.bottom ? a : b);
  }

  /// 指定したラベルで、確信度が一定以上で、特定の矩形内に含まれる検出を取得
  DetectionList filter(String label, double minConfidence, Rect rect) {
    return DetectionList(
        detections: detections
            .where((d) =>
        d.label == label &&
            d.confidence >= minConfidence &&
            d.rect.overlaps(rect))
            .toList());
  }

  /// NMSを適用
  DetectionList nms(double iouThreshold) {
    var results = <Detection>[];
    var sorted = List.of(detections);
    sorted.sort((a, b) => b.confidence.compareTo(a.confidence));
    while (sorted.isNotEmpty) {
      var best = sorted.first;
      results.add(best);
      sorted.remove(best);
      sorted.removeWhere((d) => _iou(best.rect, d.rect) > iouThreshold);
    }
    return DetectionList(detections: results);
  }

  /// IoUを計算
  double _iou(Rect a, Rect b) {
    var intersection = a.intersect(b);
    var union = a.expandToInclude(b);
    return intersection.width *
        intersection.height /
        union.width /
        union.height;
  }

  /// isNotEmpty
  bool get isNotEmpty => detections.isNotEmpty;

  /// isEmpty
  bool get isEmpty => detections.isEmpty;

  /// 検出された数
  int get length => detections.length;
}

abstract class DetectorListener {
  void onDetect(DetectionList result);
}