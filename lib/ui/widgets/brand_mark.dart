import 'package:flutter/material.dart';

/// The guitar-pick logo mark. Use [BrandMark.white] on chocolate backgrounds.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32}) : _asset = 'assets/brand/logo_mark.png';

  const BrandMark.white({super.key, this.size = 32}) : _asset = 'assets/brand/logo_mark_white.png';

  /// Height in logical pixels; the width follows the mark's aspect ratio.
  final double size;
  final String _asset;

  @override
  Widget build(BuildContext context) =>
      Image.asset(_asset, height: size, filterQuality: FilterQuality.medium, semanticLabel: 'Logo');
}
