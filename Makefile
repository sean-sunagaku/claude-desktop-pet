# ClawnPet — ビルド・導入・開発用コマンド
# `make help` でターゲット一覧を表示

APP     = build/ClawnPet.app
DEST    = /Applications/ClawnPet.app
ICONSET = build/ClawnPet.iconset

.PHONY: help build install restart run uninstall icon clean

help: ## ターゲット一覧を表示
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## ビルドして build/ClawnPet.app を作る（要 Xcode Command Line Tools）
	./build.sh

install: build ## ビルドして /Applications に配置・起動（常駐版の導入と更新）
	-pkill -f ClawnPet 2>/dev/null; sleep 0.5
	rm -rf $(DEST)
	cp -R $(APP) $(DEST)
	touch $(DEST)
	open $(DEST)
	@echo "Installed: $(DEST)"

restart: ## 常駐版（/Applications）を再起動
	-pkill -f ClawnPet 2>/dev/null; sleep 0.5
	open $(DEST)

run: build ## その場でデバッグ起動（CLAWN_DEBUG=1・フォアグラウンド・Ctrl-C で終了）
	-pkill -f ClawnPet 2>/dev/null; sleep 0.5
	CLAWN_DEBUG=1 $(APP)/Contents/MacOS/ClawnPet

uninstall: ## 常駐を停止して /Applications と設定（UserDefaults）を削除
	-pkill -f ClawnPet 2>/dev/null
	rm -rf $(DEST)
	-defaults delete com.sunagaku.clawnpet 2>/dev/null || true
	@echo "Uninstalled."

icon: ## アプリアイコンを tools/render_icon.swift から全サイズ再生成
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	swift tools/render_icon.swift $(ICONSET)/icon_16x16.png 16
	swift tools/render_icon.swift $(ICONSET)/icon_16x16@2x.png 32
	swift tools/render_icon.swift $(ICONSET)/icon_32x32.png 32
	swift tools/render_icon.swift $(ICONSET)/icon_32x32@2x.png 64
	swift tools/render_icon.swift $(ICONSET)/icon_128x128.png 128
	swift tools/render_icon.swift $(ICONSET)/icon_128x128@2x.png 256
	swift tools/render_icon.swift $(ICONSET)/icon_256x256.png 256
	swift tools/render_icon.swift $(ICONSET)/icon_256x256@2x.png 512
	swift tools/render_icon.swift $(ICONSET)/icon_512x512.png 512
	swift tools/render_icon.swift $(ICONSET)/icon_512x512@2x.png 1024
	iconutil -c icns $(ICONSET) -o Resources/AppIcon.icns
	@echo "Regenerated: Resources/AppIcon.icns（反映するには make install）"

clean: ## build/ を削除
	rm -rf build
