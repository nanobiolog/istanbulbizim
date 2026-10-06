import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/models/transit_models.dart';
import 'package:mobile_app/services/transit_api_service.dart';
import 'package:mobile_app/widgets/line_search_modal.dart';

void main() {
  testWidgets('IstanbulBizimApp launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const IstanbulBizimApp());
    expect(find.byType(IstanbulBizimApp), findsOneWidget);
  });

  testWidgets('LineSearchModal displays 14BK and filters accurately', (WidgetTester tester) async {
    String? selected;

    final testLines = [
      const LineInfo(code: '500T', desc: 'Tuzla Şifa Mahallesi - Cevizlibağ', type: 'bus'),
      const LineInfo(code: '14BK', desc: 'Çekmeköy / Parseller Mah. - Uzunçayır', type: 'bus'),
      const LineInfo(code: '14B', desc: 'Adem Yavuz Mahallesi - Kadıköy', type: 'bus'),
      const LineInfo(code: '34G', desc: 'Beylikdüzü - Söğütlüçeşme (Metrobüs)', type: 'metrobus'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LineSearchModal(
          popularLines: const ['500T', '14BK', '34G'],
          allLines: testLines,
          onSelectLine: (code) {
            selected = code;
          },
        ),
      ),
    ));

    // Initially 14BK should be in the list
    expect(find.widgetWithText(ListTile, '14BK'), findsWidgets);

    // Search for 14BK
    await tester.enterText(find.byType(TextField), '14BK');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '14BK'), findsOneWidget);
    expect(find.textContaining('Çekmeköy'), findsOneWidget);

    // Tap 14BK
    await tester.tap(find.widgetWithText(ListTile, '14BK'));
    expect(selected, '14BK');
  });

  testWidgets('LineSearchModal matches 14BK when searching by route name', (WidgetTester tester) async {
    final testLines = [
      const LineInfo(code: '500T', desc: 'Tuzla Şifa Mahallesi - Cevizlibağ', type: 'bus'),
      const LineInfo(code: '14BK', desc: 'Çekmeköy / Parseller Mah. - Uzunçayır', type: 'bus'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LineSearchModal(
          popularLines: const ['500T'],
          allLines: testLines,
          onSelectLine: (_) {},
        ),
      ),
    ));

    // Search with Turkish insensitive term "cekmekoy"
    await tester.enterText(find.byType(TextField), 'cekmekoy');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '14BK'), findsOneWidget);
  });

  test('TransitApiService extracts accurate coordinates from Metrobus corridor', () {
    final service = TransitApiService();
    final file = File('assets/data/metrobus_corridor.json');
    final parsed = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final corridor = <String, List<List<double>>>{};
    parsed.forEach((k, v) {
      if (v is List) {
        corridor[k] = v.map((pt) {
          final list = pt as List;
          return [(list[0] as num).toDouble(), (list[1] as num).toDouble()];
        }).toList();
      }
    });
    service.setMetrobusCorridor(corridor);

    // Test 34G direction D (Söğütlüçeşme -> Beylikdüzü)
    final stops34GD = [
      BusStop(code: '900011', name: 'SÖĞÜTLÜÇEŞME', district: 'Kadıköy', lat: 40.991647, lon: 29.037636),
      BusStop(code: '900081', name: 'ZİNCİRLİKUYU', district: 'Şişli', lat: 41.066232, lon: 29.014361),
      BusStop(code: '900441', name: 'B.SONDURAK', district: 'Beylikdüzü', lat: 41.022885, lon: 28.624201),
    ];

    final coordsD = service.getMetrobusCoordinates(stops34GD, 'D');
    expect(coordsD, isNotNull);
    expect(coordsD!.length, greaterThan(1000));
    // Verify first point is at Söğütlüçeşme and last point is at Beylikdüzü
    expect(coordsD.first[1], closeTo(29.037, 0.01));
    expect(coordsD.last[1], closeTo(28.624, 0.01));

    // Test 34G direction G (Beylikdüzü -> Söğütlüçeşme)
    final stops34GG = [
      BusStop(code: '900442', name: 'B.SONDURAK', district: 'Beylikdüzü', lat: 41.021588, lon: 28.626396),
      BusStop(code: '900082', name: 'ZİNCİRLİKUYU', district: 'Şişli', lat: 41.065963, lon: 29.011905),
      BusStop(code: '900012', name: 'SÖĞÜTLÜÇEŞME', district: 'Kadıköy', lat: 40.991147, lon: 29.038218),
    ];

    final coordsG = service.getMetrobusCoordinates(stops34GG, 'G');
    expect(coordsG, isNotNull);
    expect(coordsG!.length, greaterThan(1000));
    expect(coordsG.first[1], closeTo(28.626, 0.01));
    expect(coordsG.last[1], closeTo(29.038, 0.01));

    // Test subset line 34 (Zincirlikuyu -> Avcılar)
    final stops34D = [
      BusStop(code: '900081', name: 'ZİNCİRLİKUYU', district: 'Şişli', lat: 41.066232, lon: 29.014361),
      BusStop(code: '900331', name: 'AVCILAR MRK.ÜNV.KMP.', district: 'Avcılar', lat: 40.983182, lon: 28.726734),
    ];

    final coords34 = service.getMetrobusCoordinates(stops34D, 'D');
    expect(coords34, isNotNull);
    expect(coords34!.length, greaterThan(500));
    expect(coords34.first[1], closeTo(29.014, 0.01));
    expect(coords34.last[1], closeTo(28.726, 0.01));
  });
}
