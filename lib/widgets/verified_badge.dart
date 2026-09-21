import 'package:flutter/material.dart';
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 17});
  @override
  Widget build(BuildContext context) => Icon(Icons.verified, color: const Color(0xFF3EA6FF), size: size);
}
