#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════"
echo "  TamaShelf — Deploy"
echo "═══════════════════════════════════════"
echo ""

if ! command -v docker &>/dev/null; then
    echo "❌ Docker non installé"
    exit 1
fi

echo "📦 Arrêt du conteneur actuel..."
docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true

echo ""
echo "🔨 Rebuild de l'image (frontend + backend)..."
docker compose build --no-cache 2>/dev/null || docker-compose build --no-cache 2>/dev/null

echo ""
echo "🚀 Démarrage..."
docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null

echo ""
echo "✅ TamaShelf déployé !"
echo ""
echo "   🌐 http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):9999"
echo ""

echo "📋 Logs (Ctrl+C pour quitter) :"
docker compose logs -f --tail=20 2>/dev/null || docker-compose logs -f --tail=20 2>/dev/null
