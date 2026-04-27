.PHONY: dev build preview install clean setup check-deps init-submodules check-updates validate validate-build

check-deps:
	@echo "🔍 檢查必要工具..."
	@command -v node >/dev/null 2>&1 || { echo "❌ Node.js 未安裝"; exit 1; }
	@command -v npm >/dev/null 2>&1 || { echo "❌ npm 未安裝"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "❌ git 未安裝"; exit 1; }
	@echo "✅ 所有必要工具已安裝"

init-submodules:
	@echo "📦 初始化 git submodules..."
	git submodule update --init --recursive
	@echo "✅ Submodules 已初始化"

setup: check-deps init-submodules install
	@echo ""
	@echo "🎉 專案設置完成！"
	@echo "   執行 make dev 啟動開發伺服器"

install:
	cd next-site && npm install

dev:
	cd next-site && npm run dev

build:
	cd next-site && npm run build

preview: build
	npm run preview

clean:
	rm -rf next-site/out next-site/.next next-site/node_modules

check-updates:
	@echo "🔍 檢查各專案 submodule 更新..."
	@git submodule foreach 'echo "📦 $$name: $$(git log --oneline -1)"'

validate:
	@echo "🧪 執行完整驗證（含 build）..."
	python3 scripts/validate.py

validate-quick:
	@echo "🧪 快速驗證（不跑 build）..."
	python3 scripts/validate.py --no-build
