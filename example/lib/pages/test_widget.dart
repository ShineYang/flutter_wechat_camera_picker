import 'package:flutter/material.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

class TestWidget extends StatefulWidget{

  @override
  State<StatefulWidget> createState() => TestSate();
}

class TestSate extends State<TestWidget>{
  CameraController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: Colors.grey,
        child: CameraPicker(
          pickerConfig: CameraPickerConfig(
              onXFileCaptured: (file, type){
                // Future.delayed(Duration(milliseconds: 2000)).then((value){
                //   controller?.resumePreview();
                // });
                return true;
              }
          ),
          onCameraCreated: (controller){
            print('返回了 controller 初始化完成');
            this.controller = controller;
          },
        ),
      ),
    );
  }

}