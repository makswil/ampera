import 'package:flutter_face_scan/features/face_capture/data/bake/aperture_pin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('pinVerticesToFrontalPose zeros non-frontal weights on pin verts', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(0.1, 0, 0),
      Vector3(1, 0, 0),
    ];
    final List<double> frontal = <double>[0.4, 0, 0.9];
    final List<double> left = <double>[0.8, 0.7, 0.6];
    pinVerticesToFrontalPose(
      weights: <List<double>>[frontal, left],
      frontalVerts: verts,
      vertices: const <int>[0, 1],
    );

    expect(frontal[0], 0.4);
    expect(frontal[1], 1.0);
    expect(left[0], 0);
    expect(left[1], 0);
    expect(left[2], 0.6);
  });

  test('pinVerticesToFrontalPose halo expands to nearby verts', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(0.005, 0, 0),
      Vector3(1, 0, 0),
    ];
    final List<double> frontal = <double>[1, 1, 1];
    final List<double> left = <double>[0.5, 0.5, 0.5];
    pinVerticesToFrontalPose(
      weights: <List<double>>[frontal, left],
      frontalVerts: verts,
      vertices: const <int>[0],
      haloSeeds: const <int>[0],
      haloRadius: 0.012,
    );

    expect(left[0], 0);
    expect(left[1], 0);
    expect(left[2], 0.5);
  });

  test('fadeNonFrontalNearSeeds kills sides at seeds, keeps far verts', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(0.002, 0, 0),
      Vector3(0.04, 0, 0),
    ];
    final List<double> frontal = <double>[0.7, 0.7, 0.7];
    final List<double> left = <double>[0.8, 0.8, 0.8];
    fadeNonFrontalNearSeeds(
      weights: <List<double>>[frontal, left],
      verts: verts,
      seeds: const <int>[0],
      innerRadius: 0,
      outerRadius: 0.005,
    );

    expect(frontal, <double>[0.7, 0.7, 0.7]);
    expect(left[0], 0);
    expect(left[1], greaterThan(0));
    expect(left[1], lessThan(0.8));
    expect(left[2], 0.8);
  });

  test('expandVertexRings walks triangle adjacency', () {
    // 0-1-2 and 2-3-4 share vertex 2.
    const List<int> tris = <int>[0, 1, 2, 2, 3, 4];
    expect(
      expandVertexRings(seeds: const <int>[0], triangles: tris, rings: 1),
      <int>{0, 1, 2},
    );
    expect(
      expandVertexRings(seeds: const <int>[0], triangles: tris, rings: 2),
      <int>{0, 1, 2, 3, 4},
    );
  });
}
