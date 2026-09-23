import 'dart:async';
import 'package:flutter/material.dart';

class VerifiedBadge extends StatefulWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 17});
  @override State<VerifiedBadge> createState()=>_VerifiedBadgeState();
}
class _VerifiedBadgeState extends State<VerifiedBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _shine;
  Timer? _timer;
  @override void initState(){super.initState();_shine=AnimationController(vsync:this,duration:const Duration(milliseconds:650));_timer=Timer.periodic(const Duration(seconds:3),(_){if(mounted)_shine.forward(from:0);});}
  @override void dispose(){_timer?.cancel();_shine.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:_shine,builder:(_,__)=>ShaderMask(shaderCallback:(rect){final x=-1.4+(_shine.value*2.8);return LinearGradient(begin:Alignment(x-.25,-1),end:Alignment(x+.25,1),colors:const[Color(0xFF3EA6FF),Colors.white,Color(0xFF3EA6FF)],stops:const[0,.5,1]).createShader(rect);},blendMode:BlendMode.srcIn,child:Icon(Icons.verified,size:widget.size,color:const Color(0xFF3EA6FF))));
}
