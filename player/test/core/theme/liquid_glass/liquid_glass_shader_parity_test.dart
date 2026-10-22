import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_uniforms.dart';

void main() {
  test('toFloats writes exactly the floats the shader declares after uSize',
      () {
    final src = File('shaders/liquid_glass.frag').readAsStringSync();
    final decl =
        RegExp(r'^uniform\s+(float|vec2|vec3|vec4)\s+\w+\s*;', multiLine: true);
    const width = {'float': 1, 'vec2': 2, 'vec3': 3, 'vec4': 4};
    final total = decl
        .allMatches(src)
        .map((m) => width[m.group(1)]!)
        .fold<int>(0, (a, b) => a + b);
    const u = LiquidGlassUniforms(
        devicePixelRatio: 1, radius: 10, tint: Color(0x80000000));
    // uSize (2 floats) is set by the engine.
    expect(u.toFloats(const Size(100, 40)).length, total - 2);
  });
}
