# ═══════════════════════════════════════════
#  TamaShelf — Multi-stage Docker build
#  Stage 1: Build React frontend
#  Stage 2: Python backend + static files
# ═══════════════════════════════════════════

# ── Stage 1: Frontend ──
FROM node:20-alpine AS frontend-build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install
COPY frontend/ ./
RUN npm run build

# ── Stage 2: Backend ──
FROM python:3.11-slim
WORKDIR /app

# Install deps
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy backend
COPY backend/ .

# Copy built frontend
COPY --from=frontend-build /build/dist /app/static

# Create data dir
RUN mkdir -p /data

ENV TAMASHELF_DATA=/data
ENV TAMASHELF_STATIC=/app/static
ENV PYTHONUNBUFFERED=1

EXPOSE 9999

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9999", "--workers", "2"]
