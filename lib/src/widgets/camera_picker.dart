// Copyright 2019 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:bindings_compatible/bindings_compatible.dart';
import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../constants/config.dart';
import '../constants/constants.dart';
import '../constants/enums.dart';
import '../constants/styles.dart';
import '../delegates/camera_picker_text_delegate.dart';
import '../internals/extensions.dart';
import '../internals/methods.dart';
import 'exposure_point_widget.dart';

const Color _lockedColor = Colors.amber;
const Duration _kDuration = Duration(milliseconds: 300);
//初始化完成时的回调
typedef CameraCreatedCallback = void Function(CameraController);

/// Create a camera picker integrate with [CameraDescription].
/// 通过 [CameraDescription] 整合的拍照选择
///
/// The picker provides create an [AssetEntity] through the camera.
/// 该选择器可以通过拍照创建 [AssetEntity]。
class CameraPicker extends StatefulWidget {
  CameraPicker({
    Key? key,
    required this.pickerConfig,
    required this.onCameraCreated,
    Locale? locale,
  }) : super(key: key) {
    Constants.textDelegate =
        pickerConfig.textDelegate ?? cameraPickerTextDelegateFromLocale(locale);
  }
  final CameraPickerConfig pickerConfig;
  final CameraCreatedCallback onCameraCreated;

  /// Build a dark theme according to the theme color.
  /// 通过主题色构建一个默认的暗黑主题
  static ThemeData themeData(Color themeColor) {
    return ThemeData.dark().copyWith(
      primaryColor: Colors.grey[900],
      primaryColorLight: Colors.grey[900],
      primaryColorDark: Colors.grey[900],
      canvasColor: Colors.grey[850],
      scaffoldBackgroundColor: Colors.grey[900],
      bottomAppBarColor: Colors.grey[900],
      cardColor: Colors.grey[900],
      highlightColor: Colors.transparent,
      toggleableActiveColor: themeColor,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: themeColor,
        selectionColor: themeColor.withAlpha(100),
        selectionHandleColor: themeColor,
      ),
      indicatorColor: themeColor,
      appBarTheme: const AppBarTheme(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarBrightness: Brightness.dark,
          statusBarIconBrightness: Brightness.light,
        ),
        elevation: 0,
      ),
      buttonTheme: ButtonThemeData(buttonColor: themeColor),
      colorScheme: ColorScheme(
        primary: Colors.grey[900]!,
        primaryVariant: Colors.grey[900],
        secondary: themeColor,
        secondaryVariant: themeColor,
        background: Colors.grey[900]!,
        surface: Colors.grey[900]!,
        brightness: Brightness.dark,
        error: const Color(0xffcf6679),
        onPrimary: Colors.black,
        onSecondary: Colors.black,
        onSurface: Colors.white,
        onBackground: Colors.white,
        onError: Colors.black,
      ),
    );
  }

  @override
  CameraPickerState createState() => CameraPickerState();
}

class CameraPickerState extends State<CameraPicker>
    with WidgetsBindingObserver {
  /// The last exposure point offset on the screen.
  /// 最后一次手动聚焦的点坐标
  final ValueNotifier<Offset?> _lastExposurePoint =
      ValueNotifier<Offset?>(null);

  final ValueNotifier<bool> _isExposureModeDisplays =
      ValueNotifier<bool>(false);

  /// The controller for the current camera.
  /// 当前相机实例的控制器
  CameraController get controller => _controller!;
  CameraController? _controller;

  /// Available cameras.
  /// 可用的相机实例
  late List<CameraDescription> cameras;

  /// Current exposure offset.
  /// 当前曝光值
  final ValueNotifier<double> _currentExposureOffset = ValueNotifier<double>(0);

  double _maxAvailableExposureOffset = 0;
  double _minAvailableExposureOffset = 0;
  double _exposureStep = 0;

  /// The maximum available value for zooming.
  /// 最大可用缩放值
  double _maxAvailableZoom = 1;

  /// The minimum available value for zooming.
  /// 最小可用缩放值
  double _minAvailableZoom = 1;

  /// Counting pointers (number of user fingers on screen).
  /// 屏幕上的触摸点计数
  int _pointers = 0;
  double _currentZoom = 1;
  double _baseZoom = 1;

  /// The index of the current cameras. Defaults to `0`.
  /// 当前相机的索引。默认为0
  int currentCameraIndex = 0;

  /// The [Timer] for keep the [_lastExposurePoint] displays.
  /// 用于控制上次手动聚焦点显示的计时器
  Timer? _exposurePointDisplayTimer;

  Timer? _exposureModeDisplayTimer;

  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////// Global Getters //////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  CameraPickerConfig get config => widget.pickerConfig;

  /// A getter to the current [CameraDescription].
  /// 获取当前相机实例
  CameraDescription get currentCamera => cameras.elementAt(currentCameraIndex);

  /// If there's no theme provided from the user, use [CameraPicker.themeData] .
  /// 如果用户未提供主题，
  late final ThemeData _theme =
      config.theme ?? CameraPicker.themeData(C.themeColor);

  /// Get [ThemeData] of the [CameraPicker] through the key.
  /// 通过常量全局 Key 获取当前选择器的主题
  ThemeData get theme => _theme;

  CameraPickerTextDelegate get _textDelegate => Constants.textDelegate;

  @override
  void initState() {
    super.initState();
    useWidgetsBinding().addObserver(this);
    initCameras();
  }

  @override
  void dispose() {
    if (!Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIOverlays(SystemUiOverlay.values);
    }
    useWidgetsBinding().removeObserver(this);
    _controller?.dispose();
    _currentExposureOffset.dispose();
    _lastExposurePoint.dispose();
    _isExposureModeDisplays.dispose();
    _exposurePointDisplayTimer?.cancel();
    _exposureModeDisplayTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? c = _controller;
    // App state changed before we got the chance to initialize.
    if (c == null || !c.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      initCameras(currentCamera);
    }
  }

  /// Adjust the proper scale type according to the [constraints].
  /// 根据 [constraints] 获取相机预览适用的缩放。
  double _effectiveCameraScale(
    BoxConstraints constraints,
    CameraController controller,
  ) {
    final int turns = config.cameraQuarterTurns;
    final String orientation = controller.value.deviceOrientation.toString();
    // Fetch the biggest size from the constraints.
    Size size = constraints.biggest;
    // Flip the size when the preview needs to turn with an odd count of quarters.
    if ((turns.isOdd && orientation.contains('portrait')) ||
        (turns.isEven && orientation.contains('landscape'))) {
      size = size.flipped;
    }
    // Calculate scale depending on the size and camera ratios.
    double scale = size.aspectRatio * controller.value.aspectRatio;
    // Prevent scaling down.
    if (scale < 1) {
      scale = 1 / scale;
    }
    return scale;
  }

  /// Initialize cameras instances.
  /// 初始化相机实例
  Future<void> initCameras([CameraDescription? cameraDescription]) async {
    // Save the current controller to a local variable.
    final CameraController? c = _controller;
    // Dispose at last to avoid disposed usage with assertions.
    if (c != null) {
      _controller = null;
      await c.dispose();
    }
    // Then request a new frame to unbind the controller from elements.
    safeSetState(() {
      _maxAvailableZoom = 1;
      _minAvailableZoom = 1;
      _currentZoom = 1;
      _baseZoom = 1;
      // Meanwhile, cancel the existed exposure point and mode display.
      _exposureModeDisplayTimer?.cancel();
      _exposurePointDisplayTimer?.cancel();
      _lastExposurePoint.value = null;
      if (_currentExposureOffset.value != 0) {
        _currentExposureOffset.value = 0;
      }
    });
    // **IMPORTANT**: Push methods into a post frame callback, which ensures the
    // controller has already unbind from widgets.
    useWidgetsBinding().addPostFrameCallback((_) async {
      // When the [cameraDescription] is null, which means this is the first
      // time initializing cameras, so available cameras should be fetched.
      if (cameraDescription == null) {
        cameras = await availableCameras();
      }

      // After cameras fetched, judge again with the list is empty or not to
      // ensure there is at least an available camera for use.
      if (cameraDescription == null && (cameras.isEmpty)) {
        handleErrorWithHandler(
          CameraException(
            'No CameraDescription found.',
            'No cameras are available in the controller.',
          ),
          config.onError,
        );
      }

      final int preferredIndex = cameras.indexWhere(
        (CameraDescription e) =>
            e.lensDirection == config.preferredLensDirection,
      );
      final int index;
      if (preferredIndex != -1 && c == null) {
        index = preferredIndex;
        currentCameraIndex = preferredIndex;
      } else {
        index = currentCameraIndex;
      }
      // Initialize the controller with the given resolution preset.
      final CameraController newController = CameraController(
        cameraDescription ?? cameras[index],
        config.resolutionPreset,
        enableAudio: false,
        imageFormatGroup: config.imageFormatGroup,
      );

      try {
        final Stopwatch stopwatch = Stopwatch()..start();
        await newController.initialize();
        stopwatch.stop();
        realDebugPrint("${stopwatch.elapsed} for controller's initialization.");
        // Then call other asynchronous methods.
        stopwatch
          ..reset()
          ..start();
        await Future.wait(
          <Future<void>>[
            if (config.lockCaptureOrientation != null)
              newController
                  .lockCaptureOrientation(config.lockCaptureOrientation),
            newController
                .getExposureOffsetStepSize()
                .then((double value) => _exposureStep = value),
            newController
                .getMaxExposureOffset()
                .then((double value) => _maxAvailableExposureOffset = value),
            newController
                .getMinExposureOffset()
                .then((double value) => _minAvailableExposureOffset = value),
            newController
                .getMaxZoomLevel()
                .then((double value) => _maxAvailableZoom = value),
            newController
                .getMinZoomLevel()
                .then((double value) => _minAvailableZoom = value),
          ],
          eagerError: true,
        );
        stopwatch.stop();
        realDebugPrint("${stopwatch.elapsed} for config's update.");
        _controller = newController;
        widget.onCameraCreated.call(_controller!);
      } catch (e, s) {
        handleErrorWithHandler(e, config.onError, s: s);
      } finally {
        safeSetState(() {});
      }
    });
  }

  /// The method to switch cameras.
  /// 切换相机的方法
  ///
  /// Switch cameras in order. When the [currentCameraIndex] reached the length
  /// of cameras, start from the beginning.
  /// 按顺序切换相机。当达到相机数量时从头开始。
  void switchCameras() {
    ++currentCameraIndex;
    if (currentCameraIndex == cameras.length) {
      currentCameraIndex = 0;
    }
    initCameras(currentCamera);
  }

  /// Obtain the next camera description for semantics.
  CameraDescription get _nextCameraDescription {
    final int nextIndex = currentCameraIndex + 1;
    if (nextIndex == cameras.length) {
      return cameras[0];
    }
    return cameras[nextIndex];
  }

  /// The method to switch between flash modes.
  /// 切换闪光灯模式的方法
  Future<void> switchFlashesMode() async {
    final FlashMode newFlashMode;

    if(controller.value.flashMode == FlashMode.off){
      newFlashMode = FlashMode.always;
    }else {
      newFlashMode = FlashMode.off;
    }
    try {
      await controller.setFlashMode(newFlashMode);
    } catch (e, s) {
      handleErrorWithHandler(e, config.onError, s: s);
    }
  }

  Future<void> zoom(double scale) async {
    if (_maxAvailableZoom == _minAvailableZoom) {
      return;
    }
    final double zoom = (_baseZoom * scale).clamp(
      _minAvailableZoom,
      _maxAvailableZoom,
    );
    if (zoom == _currentZoom) {
      return;
    }
    _currentZoom = zoom;
    try {
      await controller.setZoomLevel(_currentZoom);
    } catch (e, s) {
      handleErrorWithHandler(e, config.onError, s: s);
    }
  }

  /// Handle when the scale gesture start.
  /// 处理缩放开始的手势
  void _handleScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  /// Handle when the double tap scale details is updating.
  /// 处理双指缩放更新
  Future<void> _handleScaleUpdate(ScaleUpdateDetails details) async {
    // When there are not exactly two fingers on screen don't scale
    if (_pointers != 2) {
      return;
    }
    zoom(details.scale);
  }

  void _restartPointDisplayTimer() {
    _exposurePointDisplayTimer?.cancel();
    _exposurePointDisplayTimer = Timer(const Duration(seconds: 5), () {
      _lastExposurePoint.value = null;
    });
  }

  void _restartModeDisplayTimer() {
    _exposureModeDisplayTimer?.cancel();
    _exposureModeDisplayTimer = Timer(const Duration(seconds: 2), () {
      _isExposureModeDisplays.value = false;
    });
  }

  /// Use the specific [mode] to update the exposure mode.
  /// 设置曝光模式
  Future<void> switchExposureMode() async {
    final ExposureMode mode = controller.value.exposureMode;
    final ExposureMode newMode;
    if (mode == ExposureMode.auto) {
      newMode = ExposureMode.locked;
    } else {
      newMode = ExposureMode.auto;
    }
    _exposurePointDisplayTimer?.cancel();
    if (newMode == ExposureMode.auto) {
      _exposurePointDisplayTimer = Timer(const Duration(seconds: 5), () {
        _lastExposurePoint.value = null;
      });
    }
    try {
      await controller.setExposureMode(newMode);
    } catch (e, s) {
      handleErrorWithHandler(e, config.onError, s: s);
    }
    _restartModeDisplayTimer();
  }

  /// Use the [details] point to set exposure and focus.
  /// 通过点击点的 [details] 设置曝光和对焦。
  Future<void> setExposureAndFocusPoint(
    Offset position,
    BoxConstraints constraints,
  ) async {
    _isExposureModeDisplays.value = false;
    // Ignore point update when the new point is less than 8% and higher than
    // 92% of the screen's height.
    if (position.dy < constraints.maxHeight / 12 ||
        position.dy > constraints.maxHeight / 12 * 11) {
      return;
    }
    realDebugPrint(
      'Setting new exposure point (x: ${position.dx}, y: ${position.dy})',
    );
    _lastExposurePoint.value = position;
    _restartPointDisplayTimer();
    _currentExposureOffset.value = 0;
    try {
      if (controller.value.exposureMode == ExposureMode.locked) {
        await controller.setExposureMode(ExposureMode.auto);
      }
      final Offset newPoint = _lastExposurePoint.value!.scale(
        1 / constraints.maxWidth,
        1 / constraints.maxHeight,
      );
      if (controller.value.exposurePointSupported) {
        controller.setExposurePoint(newPoint);
      }
      if (controller.value.focusPointSupported) {
        controller.setFocusPoint(newPoint);
      }
    } catch (e, s) {
      handleErrorWithHandler(e, config.onError, s: s);
    }
  }

  /// Update the exposure offset using the exposure controller.
  /// 使用曝光控制器更新曝光值
  Future<void> updateExposureOffset(double value) async {
    // Normalize the new exposure value if exposures have steps.
    if (_exposureStep > 0) {
      final double inv = 1.0 / _exposureStep;
      double roundedOffset = (value * inv).roundToDouble() / inv;
      if (roundedOffset > _maxAvailableExposureOffset) {
        roundedOffset = (value * inv).floorToDouble() / inv;
      } else if (roundedOffset < _minAvailableExposureOffset) {
        roundedOffset = (value * inv).ceilToDouble() / inv;
      }
      value = roundedOffset;
    }
    if (value == _currentExposureOffset.value ||
        value < _minAvailableExposureOffset ||
        value > _maxAvailableExposureOffset) {
      return;
    }
    _currentExposureOffset.value = value;
    try {
      // Use [CameraPlatform] explicitly to reduce channel calls.
      await CameraPlatform.instance.setExposureOffset(
        controller.cameraId,
        value,
      );
    } catch (e, s) {
      handleErrorWithHandler(e, config.onError, s: s);
    }
    if (!_isExposureModeDisplays.value) {
      _isExposureModeDisplays.value = true;
    }
    _restartModeDisplayTimer();
    _restartPointDisplayTimer();
  }

  /// The method to take a picture.
  /// 拍照方法
  ///
  /// The picture will only taken when [isInitialized], and the camera is not
  /// taking pictures.
  /// 仅当初始化成功且相机未在拍照时拍照。
  Future<void> takePicture() async {
    if (!controller.value.isInitialized) {
      handleErrorWithHandler(
        StateError('Camera has not initialized.'),
        config.onError,
      );
    }
    if (controller.value.isTakingPicture) {
      return;
    }
    try {
      final XFile file = await controller.takePicture();
      config.onXFileCaptured?.call(
        file,
        CameraPickerViewType.image,
      );
      _controller?.pausePreview();
    } catch (e) {
      realDebugPrint('Error when preview the captured file: $e');
      handleErrorWithHandler(e, config.onError);
    }
  }

  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  /////////////////////////// Just a line breaker ////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////

  PointerUpEventListener? get onPointerUp {
    return null;
  }

  PointerMoveEventListener? onPointerMove(BoxConstraints c) {
    return null;
  }

  GestureTapCallback? get onTap {
    return takePicture;
  }

  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  /////////////////////////// Just a line breaker ////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////

  /// Settings action section widget.
  /// 设置操作区
  ///
  /// This displayed at the top of the screen.
  /// 该区域显示在屏幕上方。
  Widget settingsAction(BuildContext context) {
    return _initializeWrapper(
      builder: (CameraValue v, __) {
        if (v.isRecordingVideo) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              //暂不显示反转摄像头
              // if (cameras.length > 1) switchCamerasButton,
              const Spacer(),
              switchFlashesButton(v),
            ],
          ),
        );
      },
    );
  }

  /// The button to switch between cameras.
  /// 切换相机的按钮
  Widget get switchCamerasButton {
    return IconButton(
      tooltip: _textDelegate.sSwitchCameraLensDirectionLabel(
        _nextCameraDescription.lensDirection,
      ),
      onPressed: switchCameras,
      icon: Icon(
        Platform.isIOS
            ? Icons.flip_camera_ios_outlined
            : Icons.flip_camera_android_outlined,
        size: 24,
      ),
    );
  }

  /// The button to switch flash modes.
  /// 切换闪光灯模式的按钮
  Widget switchFlashesButton(CameraValue value) {
    IconData icon;
    if(value.flashMode == FlashMode.off){
      icon = Icons.flash_off;
    }else{
      icon = Icons.flash_auto;
    }
    return IconButton(
      onPressed: switchFlashesMode,
      tooltip: _textDelegate.sFlashModeLabel(value.flashMode),
      icon: Icon(icon, size: 24),
    );
  }

  /// Text widget for shooting tips.
  /// 拍摄的提示文字
  Widget tipsTextWidget(CameraController? controller) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(_textDelegate.shootingTips, style: const TextStyle(fontSize: 12, color: Colors.white)),
          Text(_textDelegate.shootingTipsDesc, style: const TextStyle(fontSize: 10, color: Colors.white)),
        ],
      ),
    );
  }

  /// Shooting action section widget.
  /// 拍照操作区
  ///
  /// This displayed at the top of the screen.
  /// 该区域显示在屏幕下方。
  Widget shootingActions(
    BuildContext context,
    CameraController? controller,
    BoxConstraints constraints,
  ) {
    return SizedBox(
      child: _buildBottomBlurWidget(Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          children: <Widget>[
            if (controller?.value.isRecordingVideo != true) Expanded(child: backButton(context, constraints)) else const Spacer(),
            Expanded(
              child: Center(
                child: MergeSemantics(child: shootingButton(constraints)),
              ),
            ),
            Expanded(child: albumButton(context, constraints))
          ],
        ),
      )),
    );
  }

  /// The back button near to the [shootingButton].
  /// 靠近拍照键的返回键
  Widget backButton(BuildContext context, BoxConstraints constraints) {
    return IconButton(
      onPressed: Navigator.of(context).pop,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: Container(
        alignment: Alignment.center,
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: Colors.white12,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
      ),
    );
  }

  Widget _buildBottomBlurWidget(Widget child) => ClipRRect(
      child: Container(
        color: Colors.black26,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0), child: child),
      ));

  /// The shooting button.
  /// 拍照按钮
  Widget shootingButton(BoxConstraints constraints) {
    const Size outerSize = Size.square(84);
    const Size innerSize = Size.square(68);
    return Semantics(
      label: _textDelegate.sActionShootingButtonTooltip,
      onTap: onTap,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerMove: onPointerMove(constraints),
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox.fromSize(
            size: outerSize,
            child: Center(
              child: Container(
                width: innerSize.width,
                height:  innerSize.height,
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Color(0x4D71C9A3),
                  shape: BoxShape.circle,
                ),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF6BB193),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The back button near to the [shootingButton].
  /// 靠近拍照键的相册键
  Widget albumButton(BuildContext context, BoxConstraints constraints) {
    return IconButton(
      onPressed: config.onAlbumClick,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.add_photo_alternate_outlined, color: Colors.white, size: 26,),
    );
  }

  Widget _exposureSlider(
    ExposureMode mode,
    double size,
    double height,
    double gap,
  ) {
    final bool isLocked = mode == ExposureMode.locked;
    final Color? color = isLocked ? _lockedColor : theme.iconTheme.color;

    Widget _line() {
      return ValueListenableBuilder<bool>(
        valueListenable: _isExposureModeDisplays,
        builder: (_, bool value, Widget? child) => AnimatedOpacity(
          duration: _kDuration,
          opacity: value ? 1 : 0,
          child: child,
        ),
        child: Center(child: Container(width: 1, color: color)),
      );
    }

    return ValueListenableBuilder<double>(
      valueListenable: _currentExposureOffset,
      builder: (_, double exposure, __) {
        final double effectiveTop = (size + gap) +
            (_minAvailableExposureOffset.abs() - exposure) *
                (height - size * 3) /
                (_maxAvailableExposureOffset - _minAvailableExposureOffset);
        final double effectiveBottom = height - effectiveTop - size;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              top: effectiveTop + gap,
              child: _line(),
            ),
            Positioned.fill(
              bottom: effectiveBottom + gap,
              child: _line(),
            ),
            Positioned(
              top: (_minAvailableExposureOffset.abs() - exposure) *
                  (height - size * 3) /
                  (_maxAvailableExposureOffset - _minAvailableExposureOffset),
              child: Transform.rotate(
                angle: exposure,
                child: Icon(
                  Icons.wb_sunny_outlined,
                  size: size,
                  color: color,
                ),
              ),
            ),
            Positioned.fill(
              top: -10,
              bottom: -10,
              child: RotatedBox(
                quarterTurns: 3,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Opacity(
                    opacity: 0,
                    child: Slider(
                      value: exposure,
                      min: _minAvailableExposureOffset,
                      max: _maxAvailableExposureOffset,
                      onChanged: updateExposureOffset,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The area widget for the last exposure point that user manually set.
  /// 用户手动设置的曝光点的区域显示
  Widget _focusingAreaWidget(
    CameraValue cameraValue,
    BoxConstraints constraints,
  ) {
    Widget _buildControl(double size, double height) {
      const double verticalGap = 3;
      final ExposureMode exposureMode = cameraValue.exposureMode;
      final bool isLocked = exposureMode == ExposureMode.locked;
      return Column(
        children: <Widget>[
          ValueListenableBuilder<bool>(
            valueListenable: _isExposureModeDisplays,
            builder: (_, bool value, Widget? child) => AnimatedOpacity(
              duration: _kDuration,
              opacity: value ? 1 : 0,
              child: child,
            ),
            child: GestureDetector(
              onTap: switchExposureMode,
              child: SizedBox.fromSize(
                size: Size.square(size),
                child: Icon(
                  isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  size: size,
                  color: isLocked ? _lockedColor : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: verticalGap),
          Expanded(
            child: _exposureSlider(exposureMode, size, height, verticalGap),
          ),
          const SizedBox(height: verticalGap),
          SizedBox.fromSize(size: Size.square(size)),
        ],
      );
    }

    Widget _buildFromPoint(Offset point) {
      const double controllerWidth = 20;
      final double pointWidth = constraints.maxWidth / 5;
      final double exposureControlWidth =
          config.enableExposureControlOnPoint ? controllerWidth : 0;
      final double width = pointWidth + exposureControlWidth + 2;
      final bool shouldReverseLayout = point.dx > constraints.maxWidth / 4 * 3;
      final double effectiveLeft = math.min(
        constraints.maxWidth - width,
        math.max(0, point.dx - width / 2),
      );
      final double effectiveTop = math.min(
        constraints.maxHeight - pointWidth * 3,
        math.max(0, point.dy - pointWidth * 3 / 2),
      );
      return Positioned(
        left: effectiveLeft,
        top: effectiveTop,
        width: width,
        height: pointWidth * 3,
        child: ExcludeSemantics(
          child: Row(
            textDirection:
                shouldReverseLayout ? TextDirection.rtl : TextDirection.ltr,
            children: <Widget>[
              ExposurePointWidget(
                key: ValueKey<int>(DateTime.now().millisecondsSinceEpoch),
                size: pointWidth,
                color: theme.iconTheme.color!,
              ),
              if (config.enableExposureControlOnPoint) const SizedBox(width: 2),
              if (config.enableExposureControlOnPoint)
                SizedBox.fromSize(
                  size: Size(exposureControlWidth, pointWidth * 3),
                  child: _buildControl(controllerWidth, pointWidth * 3),
                ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<Offset?>(
      valueListenable: _lastExposurePoint,
      builder: (_, Offset? point, __) {
        if (point == null) {
          return const SizedBox.shrink();
        }
        return _buildFromPoint(point);
      },
    );
  }

  /// The [GestureDetector] widget for setting exposure point manually.
  /// 用于手动设置曝光点的 [GestureDetector]
  Widget _exposureDetectorWidget(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    void _focus(TapUpDetails d) {
      // Only call exposure point updates when the controller is initialized.
      if (_controller?.value.isInitialized ?? false) {
        Feedback.forTap(context);
        setExposureAndFocusPoint(d.globalPosition, constraints);
      }
    }

    return Positioned.fill(
      child: Semantics(
        label: _textDelegate.sCameraPreviewLabel(
          _controller?.description.lensDirection,
        ),
        image: true,
        onTap: () {
          // Focus on the center point when using semantics tap.
          final Size size = MediaQuery.of(context).size;
          final TapUpDetails details = TapUpDetails(
            kind: PointerDeviceKind.touch,
            globalPosition: Offset(size.width / 2, size.height / 2),
          );
          _focus(details);
        },
        onTapHint: _textDelegate.sActionManuallyFocusHint,
        sortKey: const OrdinalSortKey(1),
        hidden: _controller == null,
        excludeSemantics: true,
        child: GestureDetector(
          onTapUp: _focus,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _cameraPreview(
    BuildContext context, {
    required DeviceOrientation orientation,
    required BoxConstraints constraints,
  }) {
    Widget preview = Listener(
      onPointerDown: (_) => _pointers++,
      onPointerUp: (_) => _pointers--,
      child: GestureDetector(
        onScaleStart: config.enablePinchToZoom ? _handleScaleStart : null,
        onScaleUpdate: config.enablePinchToZoom ? _handleScaleUpdate : null,
        // Enabled cameras switching by default if we have multiple cameras.
        onDoubleTap: cameras.length > 1 ? switchCameras : null,
        child: _controller != null
            ? CameraPreview(controller)
            : const SizedBox.shrink(),
      ),
    );

    // Make a transformed widget if it's defined.
    final Widget? transformedWidget = config.previewTransformBuilder?.call(
      context,
      controller,
      preview,
    );
    preview = Center(child: transformedWidget ?? preview);
    // Scale the preview if the config is enabled.
    if (config.enableScaledPreview) {
      preview = Transform.scale(
        scale: _effectiveCameraScale(constraints, controller),
        child: preview,
      );
    }
    // Rotated the preview if the turns is valid.
    if (config.cameraQuarterTurns % 4 != 0) {
      preview = RotatedBox(
        quarterTurns: -config.cameraQuarterTurns,
        child: preview,
      );
    }
    return preview;
  }

  Widget _initializeWrapper({
    required Widget Function(CameraValue, Widget?) builder,
    bool Function()? isInitialized,
    Widget? child,
  }) {
    if (_controller != null) {
      return ValueListenableBuilder<CameraValue>(
        valueListenable: controller,
        builder: (_, CameraValue value, Widget? w) {
          return isInitialized?.call() ?? value.isInitialized
              ? builder(value, w)
              : const SizedBox.shrink();
        },
        child: child,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _cameraBuilder({
    required BuildContext context,
    required CameraValue value,
    required BoxConstraints constraints,
  }) {
    return RepaintBoundary(
      child: _cameraPreview(
        context,
        orientation: value.deviceOrientation,
        constraints: constraints,
      ),
    );
  }

  Widget _contentBuilder(BoxConstraints constraints) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          Semantics(
            sortKey: const OrdinalSortKey(0),
            hidden: _controller == null,
            child: settingsAction(context),
          ),
          const Spacer(),
          ExcludeSemantics(child: tipsTextWidget(_controller)),
          Semantics(
            sortKey: const OrdinalSortKey(2),
            hidden: _controller == null,
            child: shootingActions(context, _controller, constraints),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: theme,
        child: Material(
          color: Colors.black,
          child: RotatedBox(
            quarterTurns: config.cameraQuarterTurns,
            child: LayoutBuilder(
              builder: (BuildContext c, BoxConstraints constraints) => Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: <Widget>[
                  ExcludeSemantics(
                    child: _initializeWrapper(
                      builder: (CameraValue value, Widget? w) => _cameraBuilder(
                        context: c,
                        value: value,
                        constraints: constraints,
                      ),
                    ),
                  ),
                  if (config.enableSetExposure)
                    _exposureDetectorWidget(c, constraints),
                  _initializeWrapper(
                    builder: (CameraValue cameraValue, Widget? w) {
                      return _focusingAreaWidget(cameraValue, constraints);
                    },
                  ),
                  _contentBuilder(constraints),
                  if (config.foregroundBuilder != null)
                    Positioned.fill(
                      child: config.foregroundBuilder!(context, _controller),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
