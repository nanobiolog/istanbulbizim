import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/transit_models.dart';
import 'package:mobile_app/services/transit_provider.dart';
import 'package:mobile_app/widgets/bus_stop_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('BusStopDetailSheet renders modern transit UI with passing lines and approaching vehicles', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});

    late final TransitProvider provider;
    await tester.runAsync(() async {
      provider = TransitProvider();
      // Wait for assets to finish loading
      for (var i = 0; i < 100 && provider.allLines.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });

    final testStop = BusStop(
      code: '215371',
      name: 'ELALMIŞ CADDESİ',
      district: 'Ümraniye',
      direction: 'KADIKÖY 14BK',
      lat: 40.99965,
      lon: 29.12693,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BusStopDetailSheet(
            stop: testStop,
            provider: provider,
            onClose: () {},
            onSelectLine: (_) {},
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));

    // Verify original modern UI elements:
    expect(find.text('ELALMIŞ CADDESİ'), findsOneWidget);
    expect(find.text('Ümraniye'), findsOneWidget);
    expect(find.text('Durak: 215371'), findsOneWidget);
    expect(find.text('KADIKÖY 14BK'), findsOneWidget);
    expect(find.text('Yol Tarifi Al'), findsOneWidget);
    expect(find.text('Yaklaşan Araçlar'), findsOneWidget);
    expect(find.text('Geçen Hatlar'), findsOneWidget);

    // Verify passing lines section if loaded
    final lines = provider.getPassingLinesForStop(testStop);
    expect(lines, isNotEmpty);
    expect(lines.contains('20D') || lines.contains('14BK') || lines.contains('13M'), isTrue);

    await tester.pumpWidget(const SizedBox());
    provider.dispose();
  });
}
