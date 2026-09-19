import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MangaColors {
  static const Color accent = Color(0xFFFF6B35);
  static const Color accentLight = Color(0xFFFF8A5C);
  static const Color accentDark = Color(0xFFE55A2B);
  static const Color secondary = Color(0xFF7C4DFF);
  static const Color secondaryLight = Color(0xFFA47DFF);
  static const Color success = Color(0xFF2ECC71);
  static const Color warning = Color(0xFFFFB347);
  static const Color error = Color(0xFFFF4757);
  static const Color info = Color(0xFF3498DB);
  static const Color cyan = Color(0xFF00D2D3);

  static const List<Color> tagColors = [
    Color(0xFFFF6B6B),
    Color(0xFFFFB347),
    Color(0xFF6BCB77),
    Color(0xFF4ECDC4),
    Color(0xFF45B7D1),
    Color(0xFF7C4DFF),
    Color(0xFFFF6B9D),
    Color(0xFFFFA502),
    Color(0xFF2ED573),
    Color(0xFF5F27CD),
  ];

  static Color tagColor(String tag) => tagColors[tag.hashCode.abs() % tagColors.length];
}

class ThemePalette {
  final Color bg;
  final Color surface;
  final Color card;
  final Color cardHover;
  final Color input;
  final Color border;
  final Color text1;
  final Color text2;
  final Color text3;
  final Color navBg;
  final Brightness brightness;

  const ThemePalette({
    required this.bg,
    required this.surface,
    required this.card,
    required this.cardHover,
    required this.input,
    required this.border,
    required this.text1,
    required this.text2,
    required this.text3,
    required this.navBg,
    required this.brightness,
  });
}

class ThemePreset {
  final String id;
  final String label;
  final String subtitle;
  final ThemePalette palette;

  const ThemePreset({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.palette,
  });
}

class FontChoice {
  final String id;
  final String label;
  final String preview;
  final String? family;

  const FontChoice({
    required this.id,
    required this.label,
    required this.preview,
    this.family,
  });
}

class AppTheme extends ChangeNotifier {
  static AppTheme? _instance;

  static const List<ThemePreset> presets = [
    ThemePreset(
      id: 'midnight',
      label: 'Midnight Manga',
      subtitle: 'Sombre violet / orange',
      palette: ThemePalette(
        bg: Color(0xFF0F0F1A),
        surface: Color(0xFF1A1A2E),
        card: Color(0xFF222240),
        cardHover: Color(0xFF2A2A50),
        input: Color(0xFF16162B),
        border: Color(0xFF333366),
        text1: Color(0xFFF0F0FF),
        text2: Color(0xFFB0B0D0),
        text3: Color(0xFF6E6E9A),
        navBg: Color(0xFF12122A),
        brightness: Brightness.dark,
      ),
    ),
    ThemePreset(
      id: 'paper',
      label: 'Paper Manga',
      subtitle: 'Clair papier / encre',
      palette: ThemePalette(
        bg: Color(0xFFF6F1E8),
        surface: Color(0xFFFFFCF7),
        card: Color(0xFFFFFCF7),
        cardHover: Color(0xFFF2EBDF),
        input: Color(0xFFF3ECE1),
        border: Color(0xFFE0D5C5),
        text1: Color(0xFF2A221A),
        text2: Color(0xFF6A5D50),
        text3: Color(0xFF9A8F85),
        navBg: Color(0xFFFFFCF7),
        brightness: Brightness.light,
      ),
    ),
    ThemePreset(
      id: 'ocean',
      label: 'Neo Tokyo Blue',
      subtitle: 'Bleu nuit cyber',
      palette: ThemePalette(
        bg: Color(0xFF08141F),
        surface: Color(0xFF102235),
        card: Color(0xFF13304A),
        cardHover: Color(0xFF1A3A58),
        input: Color(0xFF0D1C2B),
        border: Color(0xFF28506F),
        text1: Color(0xFFE9F7FF),
        text2: Color(0xFFABC7D9),
        text3: Color(0xFF6F97B0),
        navBg: Color(0xFF0D1A28),
        brightness: Brightness.dark,
      ),
    ),
    ThemePreset(
      id: 'rose',
      label: 'Shoujo Rose',
      subtitle: 'Rose clair manga',
      palette: ThemePalette(
        bg: Color(0xFFFFF4F8),
        surface: Color(0xFFFFFFFF),
        card: Color(0xFFFFFFFF),
        cardHover: Color(0xFFFFEAF2),
        input: Color(0xFFFFEEF5),
        border: Color(0xFFF2C9D8),
        text1: Color(0xFF3D2430),
        text2: Color(0xFF7F5C6C),
        text3: Color(0xFFB58C9C),
        navBg: Color(0xFFFFFFFF),
        brightness: Brightness.light,
      ),
    ),
  ];

  static const List<FontChoice> fonts = [
    FontChoice(id: 'system', label: 'Lexend / système', preview: 'TamaShelf 123 あア鬼'),
    FontChoice(id: 'animeace', label: 'Anime Ace 2', preview: 'MANGA POWER! 123', family: 'AnimeAce2'),
    FontChoice(id: 'wildwords', label: 'CC Wild Words', preview: 'Comic bubble style!', family: 'CCWildWords'),
  ];

  ThemePreset _preset = presets.first;
  FontChoice _font = fonts.first;

  AppTheme() {
    _instance = this;
  }

  ThemePreset get preset => _preset;
  FontChoice get font => _font;
  bool get isDark => _preset.palette.brightness == Brightness.dark;

  Future<void> initForUser(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final safeUser = username.trim().isEmpty ? 'default' : username.trim().toLowerCase();
    final themeId = prefs.getString('theme_preset_$safeUser') ?? 'midnight';
    final fontId = prefs.getString('theme_font_$safeUser') ?? 'system';
    _preset = presets.firstWhere((e) => e.id == themeId, orElse: () => presets.first);
    _font = fonts.firstWhere((e) => e.id == fontId, orElse: () => fonts.first);
    _instance = this;
    notifyListeners();
  }

  Future<void> setPresetForUser(String username, String presetId) async {
    final next = presets.firstWhere((e) => e.id == presetId, orElse: () => presets.first);
    _preset = next;
    _instance = this;
    final prefs = await SharedPreferences.getInstance();
    final safeUser = username.trim().isEmpty ? 'default' : username.trim().toLowerCase();
    await prefs.setString('theme_preset_$safeUser', next.id);
    notifyListeners();
  }

  Future<void> setFontForUser(String username, String fontId) async {
    final next = fonts.firstWhere((e) => e.id == fontId, orElse: () => fonts.first);
    _font = next;
    _instance = this;
    final prefs = await SharedPreferences.getInstance();
    final safeUser = username.trim().isEmpty ? 'default' : username.trim().toLowerCase();
    await prefs.setString('theme_font_$safeUser', next.id);
    notifyListeners();
  }

  ThemePalette get palette => _preset.palette;
  Color get bgColor => palette.bg;
  Color get surfaceColor => palette.surface;
  Color get cardColor => palette.card;
  Color get cardHover => palette.cardHover;
  Color get inputColor => palette.input;
  Color get borderColor => palette.border;
  Color get t1Color => palette.text1;
  Color get t2Color => palette.text2;
  Color get t3Color => palette.text3;
  Color get shimmerBase => isDark ? const Color(0xFF2A2A50) : const Color(0xFFE8E0D6);
  Color get shimmerHighlight => isDark ? const Color(0xFF3A3A60) : const Color(0xFFFFF8F0);
  Color get navBg => palette.navBg;
  Color get shadowColor => isDark ? Colors.black54 : Colors.black12;

  static AppTheme get current => _instance ?? AppTheme();

  static Color get d => current.bgColor;
  static Color get bg => current.surfaceColor;
  static Color get c1 => current.cardColor;
  static Color get c2 => current.cardHover;
  static Color get c3 => current.cardHover;
  static Color get inp => current.inputColor;
  static Color get brd => current.borderColor;
  static Color get brf => MangaColors.accentLight;
  static Color get t1 => current.t1Color;
  static Color get t2 => current.t2Color;
  static Color get t3 => current.t3Color;
  static Color get ac => MangaColors.accent;
  static Color get acl => MangaColors.accentLight;
  static Color get grn => MangaColors.success;
  static Color get amb => MangaColors.warning;
  static Color get ros => MangaColors.error;
  static Color get cyn => MangaColors.cyan;

  ThemeData get themeData => _buildTheme(palette: palette, fontFamily: _font.family);

  static ThemeData _buildTheme({
    required ThemePalette palette,
    required String? fontFamily,
  }) {
    final brightness = palette.brightness;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: palette.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: MangaColors.accent,
        onPrimary: Colors.white,
        secondary: MangaColors.secondary,
        onSecondary: Colors.white,
        error: MangaColors.error,
        onError: Colors.white,
        surface: palette.surface,
        onSurface: palette.text1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.text1,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: palette.text1,
          letterSpacing: -0.5,
          fontFamily: fontFamily,
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.border, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.input,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MangaColors.accent, width: 2),
        ),
        labelStyle: TextStyle(color: palette.text3),
        hintStyle: TextStyle(color: palette.text3),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: MangaColors.accent,
          foregroundColor: Colors.white,
          elevation: 4,
          shadowColor: MangaColors.accent.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.5, fontFamily: fontFamily),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: MangaColors.accent,
          side: const BorderSide(color: MangaColors.accent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: palette.navBg,
        selectedItemColor: MangaColors.accent,
        unselectedItemColor: palette.text3,
        elevation: 8,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, fontFamily: fontFamily),
        unselectedLabelStyle: TextStyle(fontSize: 10, fontFamily: fontFamily),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: MangaColors.accent),
      chipTheme: ChipThemeData(
        backgroundColor: palette.input,
        selectedColor: MangaColors.accent,
        labelStyle: TextStyle(color: palette.text2, fontSize: 12, fontFamily: fontFamily),
        secondaryLabelStyle: TextStyle(color: Colors.white, fontSize: 12, fontFamily: fontFamily),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: palette.border, width: 0.5),
      ),
      dividerTheme: DividerThemeData(color: palette.border, thickness: 0.5),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.card,
        contentTextStyle: TextStyle(color: palette.text1, fontFamily: fontFamily),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(color: palette.text1, fontWeight: FontWeight.w800, fontSize: 28, letterSpacing: -1),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(color: palette.text1, fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5),
        titleLarge: base.textTheme.titleLarge?.copyWith(color: palette.text1, fontWeight: FontWeight.w700, fontSize: 18),
        titleMedium: base.textTheme.titleMedium?.copyWith(color: palette.text1, fontWeight: FontWeight.w600, fontSize: 16),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(color: palette.text1, fontSize: 15),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(color: palette.text2, fontSize: 14),
        bodySmall: base.textTheme.bodySmall?.copyWith(color: palette.text3, fontSize: 12),
        labelLarge: base.textTheme.labelLarge?.copyWith(color: palette.text1, fontWeight: FontWeight.w600, fontSize: 14),
        labelSmall: base.textTheme.labelSmall?.copyWith(color: palette.text3, fontSize: 10, letterSpacing: 0.5),
      ),
    );
  }
}
