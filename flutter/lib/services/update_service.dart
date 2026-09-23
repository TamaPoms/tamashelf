import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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

  // Télécharge l'APK vers un fichier temporaire et retourne son chemin, ou
  // null en cas d'échec. `onProgress` reçoit une valeur entre 0 et 1 (ou
  // n'est jamais appelé si le serveur ne renvoie pas de taille de contenu).
  Future<String?> downloadApk(String url, {void Function(double progress)? onProgress}) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;

      final total = response.contentLength ?? 0;
      var received = 0;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tamashelf-update.apk');
      final sink = file.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();

      if (!await _looksLikeValidZip(file)) {
        try { await file.delete(); } catch (_) {}
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  // Le serveur peut couper la connexion en cours de route sans que ça lève
  // d'erreur côté client (le flux se termine juste plus tôt que prévu),
  // laissant un .apk tronqué qu'Android refuse d'installer en silence
  // ("le package semble ne pas être valide"). On vérifie donc que le
  // fichier a bien la structure d'une archive ZIP complète : signature
  // "PK" au début, et signature de fin de répertoire central ("PK\x05\x06")
  // vers la fin -- absente si le téléchargement s'est arrêté en chemin.
  // (Ne compare pas à Content-Length : ce header peut refléter une taille
  // compressée différente des octets réellement reçus une fois décodés.)
  Future<bool> _looksLikeValidZip(File file) async {
    final length = await file.length();
    if (length < 22) return false; // plus petit que l'en-tête de fin de répertoire central
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      if (header.length < 2 || header[0] != 0x50 || header[1] != 0x4B) return false;

      final tailSize = length < 65536 ? length : 65536;
      await raf.setPosition(length - tailSize);
      final tail = await raf.read(tailSize);
      for (var i = tail.length - 4; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
          return true;
        }
      }
      return false;
    } finally {
      await raf.close();
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
