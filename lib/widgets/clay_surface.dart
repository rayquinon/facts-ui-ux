import 'package:flutter/material.dart';

class ClaySurface extends StatelessWidget {
  const ClaySurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.margin,
    this.color,
    this.clipChild = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final bool clipChild;

  static BoxDecoration decoration(
    BuildContext context, {
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(24)),
    Color? color,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final Color base = color ?? scheme.surfaceContainerHighest;
    final Color highlight = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.06),
      base,
    );
    final Color shade = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.28),
      base,
    );

    return BoxDecoration(
      borderRadius: borderRadius,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[highlight, base, shade],
        stops: const <double>[0.0, 0.55, 1.0],
      ),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: scheme.shadow.withValues(alpha: 0.50),
          blurRadius: 18,
          offset: const Offset(10, 10),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.06),
          blurRadius: 14,
          offset: const Offset(-8, -8),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    return Container(
      margin: margin,
      decoration: decoration(context, borderRadius: borderRadius, color: color),
      child: clipChild
          ? ClipRRect(borderRadius: borderRadius, child: content)
          : content,
    );
  }
}
