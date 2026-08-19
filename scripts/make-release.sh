#!/bin/bash
# scripts/make-release.sh - Локальный хелпер сборки и публикации релиза на GitHub
set -euo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST="$PROJ/app/AndroidManifest.xml"

# Читаем версию из аргумента или из AndroidManifest.xml
if [ $# -ge 1 ]; then
    NEW_VER="${1#v}"
    echo "==> Установка версии $NEW_VER в AndroidManifest.xml..."
    sed -i "s/android:versionName=\"[^\"]*\"/android:versionName=\"$NEW_VER\"/" "$MANIFEST"
fi

VERSION=$(grep -o 'android:versionName="[^"]*"' "$MANIFEST" | cut -d'"' -f2)
TAG="v$VERSION"

echo "==> Сборка APK для релиза $TAG..."
"$PROJ/app/build.sh"

echo "==> Проверка Git..."
cd "$PROJ"
if ! git diff --quiet; then
    echo "==> Фиксация изменений в git..."
    git add -A
    git commit -m "release: $TAG"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "WARN: Тег $TAG уже существует. Перезаписать? (y/N)"
    read -r ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        git tag -d "$TAG"
        git push origin ":refs/tags/$TAG" 2>/dev/null || true
    else
        echo "Отмена."
        exit 0
    fi
fi

echo "==> Создание тега $TAG..."
git tag -a "$TAG" -m "Release $TAG"

echo "==> Отправка коммитов и тега $TAG в GitHub..."
git push origin main
git push origin "$TAG"

echo "==> Готово! GitHub Actions соберёт релиз: https://github.com/dsultanr/f515-usb-wwan/releases/tag/$TAG"
