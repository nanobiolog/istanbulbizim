import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/map_screen.dart';
import 'services/transit_provider.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // A failed network request or a location error (Safari: kCLErrorLocationUnknown) must not
  // surface as an uncaught error; log it once and carry on.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled: $error');
    return true;
  };

  // Edge to edge immersive status bar
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const IstanbulBizimApp());
}

class IstanbulBizimApp extends StatelessWidget {
  const IstanbulBizimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TransitProvider()),
      ],
      // only the theme comes from the provider: don't rebuild the whole app on every data tick
      child: Selector<TransitProvider, ThemeMode>(
        selector: (_, p) => p.themeMode,
        builder: (context, themeMode, _) {
          return MaterialApp(
            title: 'İstanbul Bizim',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeMode,
            home: const MapScreen(),
          );
        },
      ),
    );
  }
}

