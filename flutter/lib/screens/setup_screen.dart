import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../theme.dart';
import 'kavita_screen.dart';
import 'komga_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  int _step = 0; // 0=url, 1=login

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    if (state.db.serverUrl.isNotEmpty) {
      _urlCtrl.text = state.db.serverUrl;
      _step = 1;
    }
  }

  Future<void> _setServer() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _error = null; });

    final state = context.read<AppState>();
    await state.db.setServer(url.startsWith('http') ? url : 'http://$url');
    setState(() { _loading = false; _step = 1; });
  }

  Future<void> _login() async {
    if (_userCtrl.text.isEmpty || _passCtrl.text.isEmpty) return;
    setState(() { _loading = true; _error = null; });

    final state = context.read<AppState>();
    final ok = await state.db.login(_userCtrl.text.trim(), _passCtrl.text);

    if (ok) {
      // Sync database
      setState(() { _error = null; _loading = true; });
      try {
        final synced = await state.syncDb();
        if (synced && mounted) {
          await context.read<AppTheme>().initForUser(state.db.currentUsername);
          Navigator.of(context).pushReplacementNamed('/home');
        } else if (mounted) {
          setState(() { 
            _error = state.error ?? 'Échec sync BDD. Vérifiez l\'endpoint /api/export/db'; 
            _loading = false; 
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() { _error = 'Erreur sync: $e'; _loading = false; });
        }
      }
    } else {
      setState(() { _error = state.db.lastError.isNotEmpty ? state.db.lastError : 'Identifiants incorrects'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.d,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [MangaColors.accent, MangaColors.secondary],
                  ),
                  boxShadow: [
                    BoxShadow(color: MangaColors.accent.withValues(alpha: 0.4), blurRadius: 20, spreadRadius: 2),
                  ],
                ),
                child: const Center(
                  child: Text('鬼', style: TextStyle(fontSize: 44, color: Colors.white, fontWeight: FontWeight.w900)),
                ),
              ),
              SizedBox(height: 16),
              Text('TamaShelf', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: AppTheme.t1, letterSpacing: -0.5)),
              SizedBox(height: 32),

              // Card
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.brd),
                ),
                child: _step == 0 ? _buildUrlStep() : _buildLoginStep(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUrlStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Serveur', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
        SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(hintText: 'http://adresse:9999'),
          style: TextStyle(color: AppTheme.t1),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _loading ? null : _setServer,
          child: _loading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Suivant'),
        ),
        const SizedBox(height: 10),
        // Kavita/Komga sont autonomes (config + associations en local) :
        // pas besoin d'un serveur TamaShelf pour les utiliser.
        TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KavitaScreen())),
          child: Text('Utiliser Kavita sans serveur TamaShelf', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
        ),
        TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KomgaScreen())),
          child: Text('Utiliser Komga sans serveur TamaShelf', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildLoginStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, color: AppTheme.t2, size: 20),
              onPressed: () => setState(() => _step = 0),
            ),
            Text(context.read<AppState>().db.serverUrl,
              style: TextStyle(color: AppTheme.t3, fontSize: 11)),
          ],
        ),
        SizedBox(height: 8),
        Text('Identifiant', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(hintText: 'Nom d\'utilisateur'),
          style: TextStyle(color: AppTheme.t1),
        ),
        SizedBox(height: 12),
        Text('Mot de passe', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          decoration: const InputDecoration(hintText: '••••••'),
          style: TextStyle(color: AppTheme.t1),
          onSubmitted: (_) => _login(),
        ),
        if (_error != null) ...[
          SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppTheme.ros, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _loading ? null : _login,
          child: _loading
            ? const Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Synchronisation...'),
              ])
            : const Text('Connexion'),
        ),
      ],
    );
  }
}
