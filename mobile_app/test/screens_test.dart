import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/rail_models.dart';
import 'package:mobile_app/models/transit_models.dart';
import 'package:mobile_app/screens/station_view_screen.dart';
import 'package:mobile_app/services/transit_provider.dart';
import 'package:mobile_app/widgets/metro_train_detail_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final phone in const [Size(1170, 2532), Size(960, 1920)]) {
    testWidgets(
      'station view shows both platforms, departures and transfers (${phone.width ~/ 3}×${phone.height ~/ 3})',
      (tester) async {
        tester.view.physicalSize = phone;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        SharedPreferences.setMockInitialValues({});
        // Created in the real zone so its async start-up (asset parsing in an isolate) progresses;
        // network is unavailable in tests, so every line falls back to its clock-anchored estimate.
        late final TransitProvider provider;
        await tester.runAsync(() async {
          provider = TransitProvider();
          for (var i = 0; i < 100 && provider.metroStations['M2'] == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        final m2 = provider.metroStations['M2']!;
        final taksim = m2.firstWhere((s) => s.name == 'TAKSIM');
        await tester.runAsync(() async {
          for (var i = 0; i < 100 && provider.railSchedule('M2') == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });

        await tester.pumpWidget(
          ChangeNotifierProvider<TransitProvider>.value(
            value: provider,
            child: MaterialApp(home: StationViewScreen(station: taksim)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('TAKSIM'), findsWidgets);
        expect(find.text('HACIOSMAN yönü peronu'), findsOneWidget);
        expect(find.text('YENIKAPI yönü peronu'), findsOneWidget);
        // F1 Taksim–Kabataş funicular interchanges here.
        expect(find.text('F1'), findsWidgets);
        await tester.scrollUntilVisible(find.text('AR ile Git'), 300);
        expect(find.text('AR ile Git'), findsOneWidget);
        expect(find.text('Rota Oluştur'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        provider.dispose();
      },
    );
  }

  testWidgets('train sheet lists next stops and data source', (tester) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final train = MetroTrainVehicle(
      id: 'M2-G-32400-0',
      lineCode: 'M2',
      systemType: 'Standart Metro',
      color: const Color(0xFF009944),
      stations: const [],
      dir: 1,
      segIdx: 3,
      progress: 0.4,
      currentSpeed: 54,
      state: 'CRUISING',
      currentLat: 41.03,
      currentLon: 28.98,
      segDurationSec: 0,
      timeInSegSec: 0,
      maxSpeed: 58,
      targetStationName: 'TAKSIM',
      prevStationName: 'SISHANE',
      remainingMeters: 420,
      etaSec: 40,
      headsign: 'HACIOSMAN',
      dirCode: 'G',
      upcoming: [
        RailStopCall(4, 'TAKSIM', now.add(const Duration(seconds: 40))),
        RailStopCall(5, 'OSMANBEY', now.add(const Duration(minutes: 2, seconds: 30))),
      ],
      official: true,
      source: 'Metro İstanbul resmî istasyon tarifeleri (GetTimeTable)',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MetroTrainDetailSheet(
              train: train,
              onClose: () {},
              onFollow3D: () {},
              statusItems: const [
                RailStatusItem(line: 'M2', message: 'Teknik arıza nedeniyle seferler 10 dk aralıkla.'),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('➔ HACIOSMAN'), findsOneWidget);
    expect(find.text('OSMANBEY'), findsOneWidget);
    expect(find.textContaining('Resmî tarifeye göre konum'), findsOneWidget);
    expect(find.textContaining('Teknik arıza'), findsOneWidget);
    expect(find.text('3D Haritada Trenle İlerle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
