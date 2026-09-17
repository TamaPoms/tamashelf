#!/usr/bin/env python3
"""
TamaShelf - Outil de build APK (autonome)
==========================================

Outil graphique (Windows) qui prend en entrée l'archive `tamashelf-flutter.tar.gz`
(fournie telle quelle, sans rien extraire à la main), et fait tout automatiquement :

    1. Extraction de l'archive dans un dossier de travail géré par l'outil
    2. Détection du projet Flutter à l'intérieur (recherche de pubspec.yaml)
    3. Vérification de l'environnement (flutter doctor)
    4. Mise à jour du numéro de version dans pubspec.yaml
    5. `flutter build apk --release`
    6. Publication du .apk obtenu sur GitHub Releases (optionnel) : le site et
       l'appli Android le proposent ensuite au téléchargement automatiquement
       (voir la constante APK_DOWNLOAD_URL du frontend et UpdateService côté
       Flutter), sans rien avoir à déployer sur le serveur TamaShelf.

Ce fichier est volontairement autonome : aucune dépendance externe (uniquement
la bibliothèque standard de Python), pour pouvoir être livré seul, en dehors
de l'archive du projet Flutter.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import queue
import zipfile
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional

import tkinter as tk
from tkinter import ttk, filedialog, messagebox


# ─────────────────────────────────────────────────────────────
#  Emplacement de l'outil / fichiers de travail
# ─────────────────────────────────────────────────────────────

def app_dir() -> Path:
    """Dossier où se trouve l'outil (fonctionne aussi bien en .py qu'en .exe
    compilé avec PyInstaller)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


SETTINGS_PATH = app_dir() / "settings.json"
# Dossier géré par l'outil pour extraire l'archive fournie par l'utilisateur.
# Réinitialisé (vidé) à chaque nouvelle archive choisie.
WORK_DIR = app_dir() / "projet_extrait"


def load_settings() -> dict:
    if SETTINGS_PATH.is_file():
        try:
            return json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def save_settings(data: dict) -> None:
    # On ne sauvegarde jamais le jeton d'accès GitHub.
    safe = {k: v for k, v in data.items() if k != "github_token"}
    try:
        SETTINGS_PATH.write_text(json.dumps(safe, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────
#  Extraction de l'archive + détection du projet Flutter
# ─────────────────────────────────────────────────────────────

class ExtractionError(Exception):
    pass


def extract_archive(archive_path: Path, dest_dir: Path, log=lambda s: None) -> None:
    """Extrait `archive_path` (.tar.gz/.tgz ou .zip) dans `dest_dir`, en vidant
    d'abord ce dossier s'il existe déjà (pour repartir propre à chaque fois)."""
    if dest_dir.exists():
        log(f"Nettoyage de l'ancien dossier de travail ({dest_dir})...")
        shutil.rmtree(dest_dir, ignore_errors=True)
    dest_dir.mkdir(parents=True, exist_ok=True)

    name = archive_path.name.lower()
    log(f"Extraction de {archive_path.name}...")

    is_tar = name.endswith(".tar.gz") or name.endswith(".tgz")
    is_zip = name.endswith(".zip")
    if not is_tar and not is_zip:
        # Le nom de fichier ne correspond à aucune extension connue (par
        # exemple un gestionnaire de téléchargement qui renomme un doublon en
        # "tamashelf-flutter.tar_3.gz") : on regarde le contenu réel du
        # fichier plutôt que de refuser tout de suite.
        if zipfile.is_zipfile(archive_path):
            is_zip = True
        elif tarfile.is_tarfile(archive_path):
            is_tar = True
        else:
            raise ExtractionError(
                "Format d'archive non reconnu (attendu : .tar.gz ou .zip)."
            )

    if is_tar:
        with tarfile.open(archive_path, "r:*") as tf:  # auto-détection gz/bz2/xz/tar simple
            _safe_extract_tar(tf, dest_dir)
    else:
        with zipfile.ZipFile(archive_path) as zf:
            _safe_extract_zip(zf, dest_dir)
    log("Extraction terminée.")


def _safe_extract_tar(tf: tarfile.TarFile, dest_dir: Path) -> None:
    dest_resolved = dest_dir.resolve()
    for member in tf.getmembers():
        member_path = (dest_dir / member.name).resolve()
        if not str(member_path).startswith(str(dest_resolved)):
            raise ExtractionError(f"Archive suspecte (chemin hors dossier) : {member.name}")
    tf.extractall(dest_dir)


def _safe_extract_zip(zf: zipfile.ZipFile, dest_dir: Path) -> None:
    dest_resolved = dest_dir.resolve()
    for member in zf.namelist():
        member_path = (dest_dir / member).resolve()
        if not str(member_path).startswith(str(dest_resolved)):
            raise ExtractionError(f"Archive suspecte (chemin hors dossier) : {member}")
    zf.extractall(dest_dir)


def find_project_root(extracted_dir: Path) -> Optional[Path]:
    """Cherche le dossier du projet Flutter (celui qui contient pubspec.yaml)
    dans l'arborescence extraite. Préfère un dossier nommé `flutter` s'il y en
    a plusieurs (c'est le nom utilisé dans l'archive officielle TamaShelf)."""
    candidates = list(extracted_dir.rglob("pubspec.yaml"))
    if not candidates:
        return None
    for c in candidates:
        if c.parent.name == "flutter":
            return c.parent
    # Sinon on prend le plus "haut" dans l'arborescence (le moins profond).
    candidates.sort(key=lambda p: len(p.parts))
    return candidates[0].parent


# ─────────────────────────────────────────────────────────────
#  Lecture / écriture du numéro de version dans pubspec.yaml
# ─────────────────────────────────────────────────────────────

# NB : la classe de fin de ligne est volontairement [ \t]* et non \s* : en mode
# MULTILINE, \s* peut "manger" le \n de fin de ligne pendant le matching (il
# backtrack ensuite sur un \n plus loin dans le fichier), ce qui corrompt le
# fichier lors du remplacement (une ligne disparaît à chaque écriture).
VERSION_RE = re.compile(r"^version:\s*([0-9A-Za-z.\-]+)(?:\+(\d+))?[ \t]*$", re.MULTILINE)

PUBSPEC_SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def is_valid_pubspec_version(version_name: str) -> bool:
    """Flutter/Dart exige un format strict X.Y.Z (exactement 3 nombres) pour la
    partie "nom de version" de pubspec.yaml. Un format comme "1.20260902" (2
    composants seulement) est accepté sans erreur par l'outil s'il n'est pas
    validé ici, mais fait planter `flutter pub get` / `flutter build apk` bien
    plus tard avec un message cryptique."""
    return bool(PUBSPEC_SEMVER_RE.match((version_name or "").strip()))


def read_pubspec_version(project_dir: Path):
    """Retourne (version_name, build_number) lus depuis pubspec.yaml, ou
    (None, None) si la ligne `version:` est introuvable."""
    pubspec = project_dir / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    m = VERSION_RE.search(text)
    if not m:
        return None, None
    return m.group(1), (m.group(2) or "")


def write_pubspec_version(project_dir: Path, version_name: str, build_number: str) -> None:
    pubspec = project_dir / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    build_number = (build_number or "").strip()
    new_line = f"version: {version_name}" + (f"+{build_number}" if build_number else "")
    new_text, n = VERSION_RE.subn(new_line, text, count=1)
    if n == 0:
        raise ValueError("Impossible de trouver la ligne 'version:' dans pubspec.yaml")
    pubspec.write_text(new_text, encoding="utf-8")


# ─────────────────────────────────────────────────────────────
#  Publication sur GitHub Releases (API REST, sans dépendance externe)
# ─────────────────────────────────────────────────────────────

GITHUB_API_VERSION = "2022-11-28"
APK_ASSET_NAME = "tamashelf.apk"


def gh_request(url, token, method="GET", json_data=None, raw_data=None, raw_content_type=None, timeout=30):
    """Requête vers l'API GitHub. `json_data` sérialise un payload JSON ;
    `raw_data`/`raw_content_type` envoient un corps brut (upload d'asset)."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
    }
    body = None
    if json_data is not None:
        body = json.dumps(json_data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif raw_data is not None:
        body = raw_data
        headers["Content-Type"] = raw_content_type or "application/octet-stream"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def github_error_message(e) -> str:
    if isinstance(e, urllib.error.HTTPError):
        try:
            data = json.loads(e.read().decode("utf-8"))
        except Exception:
            data = {}
        msg = data.get("message") or f"Erreur HTTP {e.code}"
        errors = data.get("errors")
        if errors:
            msg += " — " + "; ".join(
                (err.get("message") or err.get("code") or str(err)) if isinstance(err, dict) else str(err)
                for err in errors
            )
        if e.code == 401:
            msg += "\n\nLe jeton d'accès GitHub est invalide ou expiré."
        elif e.code == 403:
            msg += (
                "\n\nLe jeton n'a probablement pas la permission d'écrire sur ce dépôt "
                "(il faut le scope 'repo', ou 'Contents: Read and write' pour un jeton "
                "\"fine-grained\")."
            )
        elif e.code == 404:
            msg += "\n\nDépôt introuvable, ou jeton sans accès à ce dépôt."
        return msg
    if isinstance(e, urllib.error.URLError):
        return f"Impossible de joindre GitHub : {e.reason}"
    return str(e)


# ─────────────────────────────────────────────────────────────
#  Interface graphique
# ─────────────────────────────────────────────────────────────

class ApkBuilderApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("TamaShelf — Outil de build APK")
        self.root.geometry("760x680")

        self.settings = load_settings()
        self.log_queue: "queue.Queue[str]" = queue.Queue()

        self.archive_path: Optional[Path] = None
        self.project_dir: Optional[Path] = None

        self._build_ui()
        self.root.after(100, self._drain_log_queue)

        last_archive = self.settings.get("last_archive")
        if last_archive and Path(last_archive).is_file():
            self._process_archive(Path(last_archive))

    # ---- UI ----

    def _build_ui(self):
        pad = {"padx": 10, "pady": 6}

        # Étape 1 : archive
        f1 = ttk.LabelFrame(self.root, text="1. Archive du projet Flutter (.tar.gz)")
        f1.pack(fill="x", **pad)

        row = ttk.Frame(f1)
        row.pack(fill="x", padx=8, pady=8)
        self.archive_var = tk.StringVar(value="(aucune archive choisie)")
        ttk.Label(row, textvariable=self.archive_var, foreground="#555").pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Choisir tamashelf-flutter.tar.gz...", command=self._on_choose_archive).pack(side="right")

        self.project_var = tk.StringVar(value="Projet détecté : —")
        ttk.Label(f1, textvariable=self.project_var, foreground="#2a7").pack(anchor="w", padx=8, pady=(0, 8))

        # Étape 2 : environnement
        f2 = ttk.LabelFrame(self.root, text="2. Environnement Flutter")
        f2.pack(fill="x", **pad)
        ttk.Button(f2, text="Vérifier l'environnement (flutter doctor)", command=self._on_check_env).pack(
            anchor="w", padx=8, pady=8
        )

        # Étape 3 : version + build
        f3 = ttk.LabelFrame(self.root, text="3. Version et build")
        f3.pack(fill="x", **pad)

        vrow = ttk.Frame(f3)
        vrow.pack(fill="x", padx=8, pady=4)
        ttk.Label(vrow, text="Version (ex: 1.2.0) :").pack(side="left")
        self.version_var = tk.StringVar(value="1.0.0")
        ttk.Entry(vrow, textvariable=self.version_var, width=16).pack(side="left", padx=6)
        ttk.Label(vrow, text="Numéro de build :").pack(side="left", padx=(16, 0))
        self.build_number_var = tk.StringVar(value="1")
        ttk.Entry(vrow, textvariable=self.build_number_var, width=8).pack(side="left", padx=6)
        ttk.Button(vrow, text="Recharger depuis pubspec.yaml", command=self._on_reload_version).pack(side="left", padx=(16, 0))

        self.build_btn = ttk.Button(f3, text="Construire l'APK", command=self._start_build)
        self.build_btn.pack(anchor="w", padx=8, pady=8)
        self.build_btn.state(["disabled"])

        # Étape 4 : publication
        f4 = ttk.LabelFrame(self.root, text="4. Publier sur GitHub Releases (optionnel)")
        f4.pack(fill="x", **pad)

        grid = ttk.Frame(f4)
        grid.pack(fill="x", padx=8, pady=4)
        ttk.Label(grid, text="Dépôt (owner/repo) :").grid(row=0, column=0, sticky="w")
        self.repo_var = tk.StringVar(value=self.settings.get("github_repo", "TamaPoms/tamashelf"))
        ttk.Entry(grid, textvariable=self.repo_var, width=40).grid(row=0, column=1, sticky="w", padx=6)

        ttk.Label(grid, text="Jeton d'accès GitHub :").grid(row=1, column=0, sticky="w")
        self.token_var = tk.StringVar(value="")
        ttk.Entry(grid, textvariable=self.token_var, width=40, show="*").grid(row=1, column=1, sticky="w", padx=6)

        ttk.Label(grid, text="Notes (optionnel) :").grid(row=2, column=0, sticky="w")
        self.notes_var = tk.StringVar(value="")
        ttk.Entry(grid, textvariable=self.notes_var, width=40).grid(row=2, column=1, sticky="w", padx=6)

        ttk.Label(
            f4,
            text="Jeton : github.com/settings/tokens → \"Fine-grained tokens\" → accès au dépôt "
                 "ci-dessus avec la permission \"Contents: Read and write\".",
            foreground="#777", wraplength=680, justify="left",
        ).pack(anchor="w", padx=8, pady=(0, 4))

        self.publish_btn = ttk.Button(f4, text="Publier le dernier APK construit", command=self._start_publish)
        self.publish_btn.pack(anchor="w", padx=8, pady=8)
        self.publish_btn.state(["disabled"])

        # Journal
        f5 = ttk.LabelFrame(self.root, text="Journal")
        f5.pack(fill="both", expand=True, **pad)
        self.log_text = tk.Text(f5, height=14, wrap="word", state="disabled")
        self.log_text.pack(fill="both", expand=True, padx=8, pady=8)

        self.last_apk_path: Optional[Path] = None

    def log(self, msg: str):
        self.log_queue.put(msg)

    def _drain_log_queue(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                self.log_text.configure(state="normal")
                self.log_text.insert("end", msg + "\n")
                self.log_text.see("end")
                self.log_text.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(100, self._drain_log_queue)

    # ---- Étape 1 : archive ----

    def _on_choose_archive(self):
        path = filedialog.askopenfilename(
            title="Choisir l'archive tamashelf-flutter.tar.gz",
            filetypes=[("Archive Flutter", "*.tar.gz *.tgz *.zip"), ("Tous les fichiers", "*.*")],
        )
        if not path:
            return
        self._process_archive(Path(path))

    def _process_archive(self, archive_path: Path):
        self.archive_path = archive_path
        self.archive_var.set(str(archive_path))
        self.build_btn.state(["disabled"])
        self.publish_btn.state(["disabled"])
        threading.Thread(target=self._process_archive_worker, args=(archive_path,), daemon=True).start()

    def _process_archive_worker(self, archive_path: Path):
        try:
            extract_archive(archive_path, WORK_DIR, log=self.log)
        except Exception as e:
            self.log(f"❌ Échec de l'extraction : {e}")
            self.root.after(0, lambda: messagebox.showerror("Extraction impossible", str(e)))
            return

        project_dir = find_project_root(WORK_DIR)
        if not project_dir:
            self.log("❌ Aucun projet Flutter trouvé dans l'archive (pubspec.yaml introuvable).")
            self.root.after(
                0,
                lambda: messagebox.showerror(
                    "Projet introuvable",
                    "Impossible de trouver pubspec.yaml dans l'archive fournie.\n"
                    "Vérifie que le fichier choisi est bien tamashelf-flutter.tar.gz.",
                ),
            )
            return

        self.project_dir = project_dir
        self.log(f"✅ Projet Flutter détecté : {project_dir}")
        self.settings["last_archive"] = str(archive_path)
        save_settings(self.settings)

        version_name, build_number = read_pubspec_version(project_dir)
        if version_name:
            self.root.after(0, lambda: self.version_var.set(version_name))
            self.root.after(0, lambda: self.build_number_var.set(build_number or ""))
        self.root.after(0, lambda: self.project_var.set(f"Projet détecté : {project_dir}"))
        self.root.after(0, lambda: self.build_btn.state(["!disabled"]))

    # ---- Étape 2 : environnement ----

    def _on_check_env(self):
        threading.Thread(target=self._check_env_worker, daemon=True).start()

    def _check_env_worker(self):
        self.log("Vérification de l'environnement Flutter...")
        try:
            self._run_streamed(["flutter", "--version"], cwd=self.project_dir or app_dir())
            self._run_streamed(["flutter", "doctor"], cwd=self.project_dir or app_dir())
        except FileNotFoundError:
            self.log("❌ La commande 'flutter' est introuvable.")
            self.root.after(
                0,
                lambda: messagebox.showerror(
                    "Flutter introuvable",
                    "La commande 'flutter' n'a pas été trouvée.\n"
                    "Installe le SDK Flutter et assure-toi qu'il est dans le PATH.",
                ),
            )

    # ---- Étape 3 : version + build ----

    def _on_reload_version(self):
        if not self.project_dir:
            return
        version_name, build_number = read_pubspec_version(self.project_dir)
        if version_name:
            self.version_var.set(version_name)
            self.build_number_var.set(build_number or "")
            self.log(f"Version rechargée depuis pubspec.yaml : {version_name}+{build_number}")

    def _start_build(self):
        if not self.project_dir:
            messagebox.showerror("Aucun projet", "Choisis d'abord une archive valide.")
            return
        version_name = self.version_var.get().strip()
        build_number = self.build_number_var.get().strip()

        if not version_name:
            messagebox.showerror("Version manquante", "Indique un numéro de version.")
            return

        if not is_valid_pubspec_version(version_name):
            messagebox.showerror(
                "Format de version invalide",
                f"'{version_name}' n'est pas un format de version valide.\n\n"
                "Flutter exige exactement 3 nombres séparés par des points, "
                "par exemple : 1.2.0\n\n"
                "(Astuce : utilise la date sous forme AAAA.MM.JJ, par exemple 2026.09.02, "
                "plutôt que AAAAMMJJ qui ne contient que 2 nombres.)",
            )
            return

        self.build_btn.state(["disabled"])
        threading.Thread(target=self._build_worker, args=(version_name, build_number), daemon=True).start()

    def _build_worker(self, version_name: str, build_number: str):
        try:
            self.log(f"Écriture de la version {version_name}+{build_number} dans pubspec.yaml...")
            write_pubspec_version(self.project_dir, version_name, build_number)

            self.log("flutter pub get...")
            self._run_streamed(["flutter", "pub", "get"], cwd=self.project_dir)

            self.log("flutter build apk --release (peut prendre plusieurs minutes)...")
            self._run_streamed(["flutter", "build", "apk", "--release"], cwd=self.project_dir)

            apk_path = self.project_dir / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
            if not apk_path.is_file():
                self.log("❌ Build terminé mais le fichier APK est introuvable à l'emplacement attendu.")
                return

            size_mb = apk_path.stat().st_size / (1024 * 1024)
            self.log(f"✅ APK construit avec succès : {apk_path} ({size_mb:.1f} Mo)")
            self.last_apk_path = apk_path
            self.root.after(0, lambda: self.publish_btn.state(["!disabled"]))
        except FileNotFoundError:
            self.log("❌ La commande 'flutter' est introuvable. Vérifie ton installation.")
        except Exception as e:
            self.log(f"❌ Erreur pendant le build : {e}")
        finally:
            self.root.after(0, lambda: self.build_btn.state(["!disabled"]))

    def _run_streamed(self, cmd, cwd):
        self.log(f"$ {' '.join(cmd)}")
        # Lu en mode binaire puis décodé nous-mêmes (errors="replace") plutôt
        # que text=True : sur Windows, la sortie de `flutter`/`gradle` peut
        # contenir des octets qui ne correspondent pas à l'encodage par défaut
        # de la console (accents dans un chemin, caractères de dessin de
        # boîte...), ce qui faisait planter tout le build avec une
        # UnicodeDecodeError avant même d'avoir pu lire le vrai message
        # d'erreur de Flutter.
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            shell=(sys.platform == "win32"),
        )
        for raw_line in proc.stdout:
            self.log(raw_line.decode("utf-8", errors="replace").rstrip("\r\n"))
        proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(f"La commande a échoué (code {proc.returncode})")

    # ---- Étape 4 : publication (GitHub Releases) ----

    def _start_publish(self):
        if not self.last_apk_path or not self.last_apk_path.is_file():
            messagebox.showerror("Aucun APK", "Construis d'abord un APK avant de publier.")
            return
        repo = self.repo_var.get().strip().strip("/")
        token = self.token_var.get().strip()
        version_name = self.version_var.get().strip()
        build_number = self.build_number_var.get().strip()
        notes = self.notes_var.get().strip()

        if not repo or "/" not in repo:
            messagebox.showerror("Dépôt invalide", "Indique le dépôt au format owner/repo (ex: TamaPoms/tamashelf).")
            return
        if not token:
            messagebox.showerror("Jeton manquant", "Renseigne un jeton d'accès personnel GitHub.")
            return

        self._save_current_settings()
        self.publish_btn.state(["disabled"])
        threading.Thread(
            target=self._publish_worker, args=(repo, token, version_name, build_number, notes), daemon=True
        ).start()

    def _publish_worker(self, repo, token, version_name, build_number, notes):
        try:
            owner, name = repo.split("/", 1)
            api_base = f"https://api.github.com/repos/{owner}/{name}"
            tag = f"v{version_name}"

            self.log(f"Création de la release {tag} sur {repo}...")
            body_text = notes or f"Build automatique de l'appli Android — version {version_name}+{build_number}."
            release = None
            try:
                release = gh_request(
                    f"{api_base}/releases",
                    token,
                    method="POST",
                    json_data={
                        "tag_name": tag,
                        "name": f"TamaShelf {version_name}",
                        "body": body_text,
                        "draft": False,
                        "prerelease": False,
                    },
                )
                self.log(f"✅ Release créée : {release.get('html_url')}")
            except urllib.error.HTTPError as e:
                if e.code == 422:
                    # Tag déjà utilisé par une release existante (ex: rebuild du
                    # même numéro de version) : on réutilise cette release et on
                    # remplacera juste l'APK dessus.
                    self.log(f"La release {tag} existe déjà, réutilisation...")
                    release = gh_request(f"{api_base}/releases/tags/{tag}", token)
                else:
                    raise

            release_id = release["id"]
            for asset in release.get("assets", []):
                if asset.get("name") == APK_ASSET_NAME:
                    self.log(f"Suppression de l'ancien {APK_ASSET_NAME} sur cette release...")
                    gh_request(f"{api_base}/releases/assets/{asset['id']}", token, method="DELETE")

            local_size = self.last_apk_path.stat().st_size
            self.log(f"Envoi de {APK_ASSET_NAME} ({local_size / (1024*1024):.1f} Mo)...")
            upload_url = f"https://uploads.github.com/repos/{owner}/{name}/releases/{release_id}/assets?name={APK_ASSET_NAME}"
            asset = gh_request(
                upload_url,
                token,
                method="POST",
                raw_data=self.last_apk_path.read_bytes(),
                raw_content_type="application/vnd.android.package-archive",
                timeout=180,
            )

            # GitHub peut répondre avec succès (201) même si l'upload a été
            # interrompu en cours de route côté serveur, en ne stockant que le
            # début du fichier : on vérifie que la taille annoncée par GitHub
            # correspond bien à celle de l'APK local avant de crier victoire,
            # pour ne pas publier silencieusement un .apk tronqué que
            # personne ne pourra installer.
            remote_size = asset.get("size")
            if remote_size != local_size:
                raise RuntimeError(
                    f"L'upload semble incomplet : GitHub a stocké {remote_size} octets, "
                    f"attendu {local_size}. Réessaie la publication."
                )

            self.log(f"✅ Publié avec succès : {asset.get('browser_download_url')}")
            self.root.after(
                0,
                lambda: messagebox.showinfo(
                    "Publication réussie",
                    f"L'APK version {version_name} est maintenant disponible sur GitHub Releases "
                    "(le site et l'appli Android le proposeront automatiquement).",
                ),
            )
        except Exception as e:
            msg = github_error_message(e) if isinstance(e, (urllib.error.HTTPError, urllib.error.URLError)) else str(e)
            self.log(f"❌ Échec de la publication : {msg}")
            self.root.after(0, lambda: messagebox.showerror("Échec de la publication", msg))
        finally:
            self.root.after(0, lambda: self.publish_btn.state(["!disabled"]))

    def _save_current_settings(self):
        self.settings["github_repo"] = self.repo_var.get().strip()
        if self.archive_path:
            self.settings["last_archive"] = str(self.archive_path)
        save_settings(self.settings)


def main():
    root = tk.Tk()
    ApkBuilderApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
