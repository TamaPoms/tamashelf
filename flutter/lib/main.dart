import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'theme.dart';
import 'screens/setup_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  final appState = AppState();
  await appState.db.init();
  final appTheme = AppTheme();
  await appTheme.initForUser(appState.db.currentUsername);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        ChangeNotifierProvider.value(value: appTheme),
      ],
      child: const TamaShelfApp(),
    ),
  );
}

class TamaShelfApp extends StatelessWidget {
  const TamaShelfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppTheme>(
      builder: (ctx, theme, _) => MaterialApp(
        title: 'TamaShelf',
        theme: theme.themeData,
        debugShowCheckedModeBanner: false,
        home: const SplashScreen(),
        routes: {
          '/setup': (_) => const SetupScreen(),
          '/home': (_) => const HomeScreen(),
        },
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _logoScale;
  late Animation<double> _titleOpacity;
  late Animation<Offset> _titleSlide;
  late Animation<double> _subtitleOpacity;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

    _logoScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.4, curve: Curves.elasticOut)),
    );
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.3, 0.6, curve: Curves.easeOut)),
    );
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.3, 0.6, curve: Curves.easeOut)),
    );
    _subtitleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.5, 0.8, curve: Curves.easeOut)),
    );

    _ctrl.forward();
    _initAndNavigate();
  }

  Future<void> _initAndNavigate() async {
    final state = context.read<AppState>();
    await state.init();
    await context.read<AppTheme>().initForUser(state.db.currentUsername);
    
    // Wait at least for animation
    await Future.delayed(const Duration(milliseconds: 2200));

    if (!mounted) return;
    final route = state.db.hasLocalDb ? '/home' : '/setup';
    Navigator.of(context).pushReplacementNamed(route);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<AppTheme>();

    return Scaffold(
      backgroundColor: theme.bgColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated logo
            ScaleTransition(
              scale: _logoScale,
              child: Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [MangaColors.accent, MangaColors.secondary],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: MangaColors.accent.withValues(alpha: 0.4),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Center(
                  child: Text('鬼', style: TextStyle(fontSize: 52, color: Colors.white, fontWeight: FontWeight.w900)),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Title
            SlideTransition(
              position: _titleSlide,
              child: FadeTransition(
                opacity: _titleOpacity,
                child: Text(
                  'TamaShelf',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                    color: theme.t1Color,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Subtitle
            FadeTransition(
              opacity: _subtitleOpacity,
              child: Text(
                'Votre bibliotheque manga',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.t3Color,
                  letterSpacing: 1,
                ),
              ),
            ),

            const SizedBox(height: 40),

            // Loading indicator
            FadeTransition(
              opacity: _subtitleOpacity,
              child: SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: MangaColors.accent.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
