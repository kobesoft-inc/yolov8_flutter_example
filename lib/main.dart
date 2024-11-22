import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'preview.dart';
import 'detector.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> implements DetectorListener {
  late CameraController _controller;
  late Future<void> _initializeFuture;

  late Detector _detector;
  bool _detectionStarted = false;
  bool _isDetecting = false;
  DetectionList _detectionList = DetectionList();

  @override
  void initState() {
    super.initState();
    _initializeFuture = _initialize();
  }

  /// カメラと物体検出器を初期化する
  Future<void> _initialize() async {
    _detector = Detector(
      modelPath: 'assets/model.tflite',
      labelsPath: 'assets/labels.txt',
      listener: this,
    );

    final cameras = await availableCameras();
    final firstCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );

    _controller = CameraController(
      firstCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    await _controller.initialize();
  }

  /// カメラの映像を取得し、物体検出を開始する
  void _startCamera() {
    if (!_detectionStarted) {
      _detectionStarted = true;
      _controller.startImageStream((image) async {
        if (!_isDetecting) {
          _isDetecting = true;
          await _detector.detectWithCameraImage(image);
          _isDetecting = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text('撮影'),
        ),
        body: FutureBuilder<void>(
          future: _initializeFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done) {
              print(_controller.value.aspectRatio);
              _startCamera();
              return AspectRatio(
                  aspectRatio: 1.0 / _controller.value.aspectRatio,
                  child: Stack(
                    children: [
                      Positioned.fill(child: CameraPreview(_controller)),
                      Positioned.fill(
                          child: DetectorPreview(detectionList: _detectionList))
                    ],
                  ));
            } else {
              return const Center(child: CircularProgressIndicator());
            }
          },
        ),
      ),
    );
  }

  @override
  void onDetect(DetectionList detectionList) {
    setState(() {
      _detectionList = detectionList.filterByConfidence(0.5).nms(0.5);
    });
  }
}
