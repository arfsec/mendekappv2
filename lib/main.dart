import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_service.dart';
import 'services/notif_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiService.instance.init();
  await NotifService.instance.init();
  String? initialAuthError;
  if (ApiService.instance.session != null &&
      ApiService.instance.isSessionExpired) {
    initialAuthError = 'License expired, silakan meminta yang baru.';
    await ApiService.instance.logout();
    await NotifService.instance.showLicenseExpiredNotification(initialAuthError);
  }
  final String? launchPayload = await NotifService.instance.getLaunchPayload();
  runApp(
    MendekArenaApp(
      initialPayload: launchPayload,
      initialAuthError: initialAuthError,
    ),
  );
}

class MendekArenaApp extends StatelessWidget {
  final String? initialPayload;
  final String? initialAuthError;
  const MendekArenaApp({
    super.key,
    this.initialPayload,
    this.initialAuthError,
  });

  @override
  Widget build(BuildContext context) {
    final Color appleBlue = ApiService.instance.remoteConfig.accentColor;
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: appleBlue,
      brightness: Brightness.light,
    );

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Mendek Arena Masteran Burung',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF1C1C1E),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1C1C1E),
          ),
          titleMedium: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
          bodyLarge: TextStyle(fontSize: 16, color: Color(0xFF1C1C1E)),
          bodyMedium: TextStyle(fontSize: 15, color: Color(0xFF3A3A3C)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: appleBlue,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      home: ApiService.instance.hasValidSession
          ? HomeScreen(initialPayload: initialPayload)
          : LoginScreen(
              pendingPayload: initialPayload,
              initialError: initialAuthError,
            ),
    );
  }
}
