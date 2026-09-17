import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String? notes;

  UpdateInfo({required this.version, required this.downloadUrl, this.notes});
}

class UpdateService {
  static const _latestReleaseUrl =
      'https://api.github.com/repos/TamaPoms/tamashelf/releases/latest';
  static const _fallbackDownloadUrl =
      'https://github.com/TamaPoms/tamashelf/releases/latest/download/tamashelf.apk';

  // Returns update info when a newer version is published on GitHub
  // Releases than the currently installed app, or null if up to date /
  // unreachable.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final current = await PackageInfo.fromPlatform();
      final resp = await http
          .get(Uri.parse(_latestReleaseUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final data = json.decode(resp.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').trim();
      final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      if (latestVersion.isEmpty || _compareVersions(latestVersion, current.version) <= 0) {
        return null;
      }

      final assets = (data['assets'] as List?) ?? const [];
      String? downloadUrl;
      for (final a in assets) {
        if (a is Map && a['name'] == 'tamashelf.apk') {
          downloadUrl = a['browser_download_url'] as String?;
          break;
        }
      }

      return UpdateInfo(
        version: latestVersion,
        downloadUrl: downloadUrl ?? _fallbackDownloadUrl,
        notes: data['body'] as String?,
      );
    } catch (_) {
      // Pas de réseau, GitHub inaccessible, réponse inattendue... on ignore
      // silencieusement : ce n'est qu'une notification optionnelle.
      return null;
    }
  }

  // Compare deux versions "X.Y.Z..." composées uniquement de nombres
  // séparés par des points (le format imposé par pubspec.yaml, y compris le
  // style date "1.2026.0917"). Retourne >0 si [a] est plus récent que [b].
  int _compareVersions(String a, String b) {
    final pa = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final pb = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va - vb;
    }
    return 0;
  }
}
