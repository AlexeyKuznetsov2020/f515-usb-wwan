#!/bin/bash
# scripts/make-release.sh - Локальная сборка и публикация релиза на GitHub через gh CLI
set -euo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST="$PROJ/app/AndroidManifest.xml"
APK="$PROJ/app/F515UsbWwanApp.apk"

# Читаем/обновляем версию
if [ $# -ge 1 ]; then
    NEW_VER="${1#v}"
    echo "==> Установка версии $NEW_VER в AndroidManifest.xml..."
    sed -i "s/android:versionName=\"[^\"]*\"/android:versionName=\"$NEW_VER\"/" "$MANIFEST"
    CURR_CODE=$(grep -o 'android:versionCode="[^"]*"' "$MANIFEST" | cut -d'"' -f2)
    NEW_CODE=$((CURR_CODE + 1))
    sed -i "s/android:versionCode=\"[^\"]*\"/android:versionCode=\"$NEW_CODE\"/" "$MANIFEST"
fi

VERSION=$(grep -o 'android:versionName="[^"]*"' "$MANIFEST" | cut -d'"' -f2)
TAG="v$VERSION"

echo "==> Локальная сборка и подпись APK ($TAG)..."
"$PROJ/app/build.sh"

echo "==> Фиксация изменений в Git..."
cd "$PROJ"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "release: $TAG"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "WARN: Тег $TAG уже существует локально. Перезаписываю..."
    git tag -d "$TAG"
    git push origin ":refs/tags/$TAG" 2>/dev/null || true
fi

echo "==> Создание тега $TAG..."
git tag -a "$TAG" -m "Release $TAG"

echo "==> Отправка коммитов в GitHub..."
git push origin main
git push origin "$TAG"

echo "==> Публикация релиза через GitHub CLI..."
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$APK" --clobber
else
    gh release create "$TAG" "$APK" --title "$TAG" --generate-notes
fi

echo "==> Релиз $TAG успешно опубликован: https://github.com/dsultanr/f515-usb-wwan/releases/tag/$TAG"
