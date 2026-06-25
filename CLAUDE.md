# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作时提供指导。

## 项目概述

Immich 是一个自托管的照片和视频管理方案。基于 AGPLv3 协议的 monorepo，使用 pnpm workspaces 管理。

## 开发命令

所有主要命令使用 `mise`（任务运行器 + 工具管理器）。在仓库根目录执行 `mise`。

### 环境管理

```bash
mise dev           # 启动完整开发环境（Docker Compose：PostgreSQL、Redis、server、web、ML）
mise dev-down      # 停止开发环境
mise dev-update    # 重新构建并重启开发环境
mise e2e           # 启动 e2e 测试环境
mise e2e-down      # 停止 e2e 测试环境
mise e2e-dev       # 启动 e2e 开发环境（热重载）
```

### 构建与代码生成

```bash
mise plugins       # 构建 SDK + 插件包（server/web 开发的前置条件）
mise open-api      # 构建插件、server，生成 OpenAPI 规范，生成 TS + Dart SDK
mise clean         # 删除所有 node_modules、dist、build、coverage 目录
mise sql           # 打开开发数据库的 SQL shell
```

### 运行单个测试

```bash
# Server 单元测试（Vitest，文件位于 src/**/*.spec.ts）
pnpm --filter immich test -- -t "test name pattern"

# Server 中型/集成测试（server/test/medium/specs/**/*.spec.ts）
pnpm --filter immich test:medium -- -t "test name pattern"

# Web 测试
pnpm --filter immich-web test -- -t "test name pattern"

# ML 测试
cd machine-learning && uv run pytest -k "test name pattern"

# E2E API 测试（需要运行中的 e2e 环境）
mise //e2e:test -- -t "test name pattern"

# E2E Web 测试（Playwright，需要运行中的 e2e 环境）
mise //e2e:test-web -- -g "test name pattern"
```

### PR 检查清单（参考 docs/docs/developer/pr-checklist.md）

**Web：**
```bash
mise //web:lint              # ESLint
mise //web:format            # Prettier
mise //web:check-svelte      # svelte-check 类型检查
mise //web:check-typescript  # tsc --noEmit
mise //web:test              # Vitest 单元测试
# 一键全部：
mise //web:checklist
```

**Server：**
```bash
mise //server:lint           # ESLint
mise //server:format         # Prettier
mise //server:check          # tsc --noEmit
mise //server:test           # Vitest 单元测试
# 一键全部：
mise //server:checklist
```

**Mobile：**
```bash
mise //mobile:codegen        # build_runner 代码生成
mise //mobile:lint           # Dart Analyzer + DCM
mise //mobile:format         # Dart Formatter
mise //mobile:test           # Flutter 测试
# 一键全部：
mise //mobile:checklist
```

**Machine Learning：**
```bash
mise //machine-learning:lint     # ruff
mise //machine-learning:format   # ruff format
mise //machine-learning:check    # mypy 类型检查
mise //machine-learning:test     # pytest
# 一键全部：
mise //machine-learning:checklist
```

**自动修复命令：**
```bash
mise //web:lint-fix              # 自动修复 ESLint 问题
mise //web:format-fix            # 自动修复 Prettier 格式问题
mise //server:lint-fix           # 自动修复 ESLint 问题
mise //server:format-fix         # 自动修复 Prettier 格式问题
mise //mobile:lint-fix           # 自动修复 Dart lint 问题
```

## 架构

### 顶层结构

```
immich/
├── server/              # NestJS 后端（TypeScript、Kysely、BullMQ）
├── web/                 # SvelteKit SPA 前端（Svelte 5、TailwindCSS 4）
├── mobile/              # Flutter 移动应用（Riverpod、Drift/SQLite）
├── machine-learning/    # Python FastAPI ML 服务（ONNX Runtime）
├── packages/
│   ├── cli/             # CLI 上传/下载工具
│   ├── sdk/             # 自动生成的 TypeScript API 客户端
│   ├── plugin-core/     # 插件运行环境（Extism）
│   ├── plugin-sdk/      # 插件 SDK，供开发者使用
│   └── e2e-auth-server/ # e2e 测试用的模拟 OAuth 服务
├── e2e/                 # 端到端测试（Vitest API + Playwright Web）
├── open-api/            # OpenAPI 规范 + 代码生成模板
├── docker/              # dev/prod/e2e 的 Docker Compose 文件
├── i18n/                # 国际化 JSON 文件
└── docs/                # 文档站点
```

### Server 架构（`server/src/`）

Server 大致遵循 **六边形架构**：核心业务逻辑在 `services/`，技术相关的实现在 `repositories/`。

#### 三种 Worker 模式

`server/src/main.ts` 管理 worker 生命周期。每种 worker 运行不同的 NestJS 模块：

| Worker | 模块 | 进程模型 | 职责 |
|--------|------|----------|------|
| `ImmichWorker.Api` | `ApiModule` | `fork()`（子进程） | HTTP + SSR |
| `ImmichWorker.Microservices` | `MicroservicesModule` | `new Worker()`（worker 线程） | BullMQ 后台作业 |
| `ImmichWorker.Maintenance` | `MaintenanceModule` | `new Worker()`（worker 线程） | 只读维护模式 |

`IWorker` 注入令牌（`server/src/constants.ts`）让各 service 知道自己运行在哪种 Worker 模式下。每个模块通过 `{ provide: IWorker, useValue: ImmichWorker.X }` 提供。

#### 依赖注入模式（桶导出）

`repositories/index.ts` 导出一个平铺的 `repositories` 数组，包含所有仓库类。`services/index.ts` 导出一个平铺的 `services` 数组。在 `app.module.ts` 中组装：

```typescript
const common = [...repositories, ...services, GlobalExceptionFilter];
// ApiModule 和 MicroservicesModule 都使用 ...common
// MaintenanceModule 使用最小子集
```

#### BaseService 模式

所有 service 继承 `BaseService`（`server/src/services/base.service.ts`），它通过构造函数注入所有约 50+ 个 repository。这意味着任意 service 都可以直接使用任意 repository，无需显式配置 DI——基类提供了所有这些。

#### ConfigRepository——直接实例化

`ConfigRepository` 通过 `new ConfigRepository()` 在 NestJS DI 外部直接实例化（在 `app.module.ts` 模块设置阶段），因为 NestJS 启动前就需要使用它。它读取环境变量，为 BullMQ、Kysely、OpenTelemetry 和 CLS 模块提供配置。运行时使用 `getConfig()` / `updateConfig()` 访问配置。

#### 事件系统

`EventRepository` 实现了进程内事件总线。在 `BaseModule.onModuleInit()` 中通过 `eventRepository.setup({ services })` 初始化，然后触发 `AppBootstrap` 启动各 service 初始化。关键事件：

- **应用生命周期**：`AppBootstrap`、`AppShutdown`、`AppRestart`
- **配置**：`ConfigInit`、`ConfigUpdate`、`ConfigValidate`
- **资产**：`AssetCreate`、`AssetTag`、`AssetTrash`、`AssetHide` 等
- **相册**：`AlbumUpdate`、`AlbumInvite`
- 还有用户、人物、库、伙伴、通知等相关事件

#### 认证

`AuthGuard`（`server/src/middleware/auth.guard.ts`）支持多种认证方式：
- Session cookie（`ImmichCookie.AccessToken`）
- 通过 `x-api-key` 头的 API Key
- 通过 `x-immich-share-key` 头 + slug 查询参数的共享链接令牌
- OAuth

#### 目录参考

- **controllers/** — REST API 端点。使用 Zod 验证（通过 `nestjs-zod`），而非 class-validator。
- **services/** — 业务逻辑。继承 `BaseService`。
- **repositories/** — 通过 Kysely 进行数据访问（非 ORM）。每个 repository 对应一个 `server/src/queries/*.repository.sql` 文件，导出命名的 SQL 模板字面量。
- **cores/** — 非 DI 的核心业务逻辑（如 `StorageCore`）。与 `services/` 不同，不使用 NestJS DI。
- **schema/** — Kysely 表定义（`tables/*.table.ts`）、迁移（`migrations/*.ts`）。还包括：
  - `index.ts` — 中心 schema 注册表：`ImmichDatabase` 类（表 + 函数 + PG 枚举）以及整个代码库中用于 Kysely 查询的 `DB` 接口。
  - `enums.ts` — 通过 `@immich/sql-tools` 的 `registerEnum()` 进行 PostgreSQL 枚举注册（与定义 TypeScript 领域枚举的 `src/enum.ts` 不同）。
  - `functions.ts` — PostgreSQL 函数定义。
- **middleware/** — Auth 守卫、异常过滤器、文件上传拦截器、日志/错误拦截器。
- **dtos/** — 基于 Zod 的请求/响应 DTO。
- **enum.ts** — 中央枚举文件，定义所有领域枚举、作业名称、队列名称、权限等。许多枚举有配套的 Zod schema 用于 OpenAPI 生成（如 `AssetTypeSchema`）。
- **constants.ts** — 全局常量：版本号、扩展名称、向量索引表、分页大小。
- **workers/** — 三种 worker 入口：`api.ts`、`microservices.ts`、`maintenance.ts`。
- **commands/** — 通过 Nest Commander 实现的 CLI 命令。

#### 关键技术

- **数据库**：PostgreSQL + Kysely（非 ORM）。扩展：`cube`、`earthdistance`、`vector`、`vchord`、`pg_trgm`、`uuid-ossp`、`unaccent`、`plpgsql`。
- **Schema 管理**：`@immich/sql-tools` 包——声明式表/函数/枚举定义，自动生成迁移。
- **作业队列**：BullMQ + Redis。队列名称在 `QueueName` 枚举中，作业名称在 `JobName` 枚举中。Microservices worker 处理作业。
- **验证**：`nestjs-zod`——全局 `ZodValidationPipe` 和 `ZodSerializerInterceptor` 应用于所有模块。
- **实时通信**：通过 `WebsocketRepository` 实现的 Socket.io。
- **可观测性**：OpenTelemetry。

### Web 架构（`web/src/`）

SvelteKit + `@sveltejs/adapter-static`（SPA 模式，由 API server 托管）。Svelte 5 运行在 legacy 模式（尚未启用 runes）。

#### 路由约定

基于文件系统的 SvelteKit 路由。布局分组：
- `routes/(user)/` — 已认证用户组（`(user)` 是布局分组，不影响 URL）。使用 `[[photos=photos]]/[[assetId=id]]` 可选参数：`[[photos=photos]]` 启用照片网格视图，`[[assetId=id]]` 打开资产查看器。
- `routes/auth/` — 登录、注册等。
- `routes/admin/` — 管理员设置。
- `routes/link/` — 共享链接。
- `routes/maintenance/` — 维护模式。

#### Lib 目录（`web/src/lib/`）

- `components/` — 共享 UI 组件，按功能组织（album-page、asset-viewer、faces-page、share-page、sidebar、admin-settings 等）
- `stores/` — Svelte writable stores（全局状态：user、websocket、upload、preferences、search 等）
- `managers/` — UI 与 API 之间的业务逻辑抽象层
- `services/` — API 调用封装
- `workers/` — Web Worker 模块
- `actions/` — SvelteKit 表单动作
- `elements/` — 基础 UI 元素
- `utils/` — 工具函数
- `modals/` — 模态对话框组件

#### 关键技术

- **样式**：Tailwind CSS v4，`@immich/ui` 共享组件库。
- **API 客户端**：`@immich/sdk` 自动生成包——绝不使用原始 HTTP 调用。
- **地图**：Maplibre GL。
- **360° 图片**：Photo Sphere Viewer。
- **视频**：HLS.js 流媒体播放。
- **i18n**：`svelte-i18n` + ICU message format。翻译由 [Weblate](https://hosted.weblate.org/projects/immich/immich/) 管理。

### Mobile 架构（`mobile/lib/`）

Flutter 应用，采用领域驱动架构。使用 **Drift**（SQLite）进行本地持久化——不是 Isar（代码库已从 Isar 迁移到 Drift；部分变量名可能仍引用 "isar"，但实际依赖是 Drift）。

#### 架构规则（来自 `domain/README.md`）

- **Entities**（`infrastructure/entities/`）— 存储在本地数据库中的数据类。
- **Models**（`domain/models/`）— 仅存在于内存中的临时数据类。
- **Repositories**（`infrastructure/repositories/`、`repositories/`）— 唯一允许使用外部数据类（如 OpenAPI DTO）的地方。Repository 接口绝不能暴露外部数据类——只能暴露 Entity 和 Model 类型。
- **Services**（`domain/services/`）— 业务逻辑，通过 `providers/` 中的 Riverpod provider 暴露。
- **表现层**不应直接使用 repository——始终通过领域 service 访问。
- 新代码必须遵循此架构。

#### 关键目录

- `domain/models/` — 业务数据模型（album、asset、person、config 等）
- `domain/services/` — 业务逻辑 service（sync、backup、store 等）
- `providers/` — Riverpod provider，按领域组织（album、backup、auth、map 等）
- `pages/` — UI 页面
- `infrastructure/` — 平台特定实现（数据库、文件系统、repositories）
- `routing/` — Auto Route 配置
- `extensions/` — Dart 扩展方法

#### 关键技术

- **状态管理**：Riverpod（`hooks_riverpod`）
- **本地数据库**：Drift（`drift_sqlite_async`）
- **API 客户端**：自动生成的 Dart SDK，位于 `mobile/openapi/`
- **后台任务**：`background_downloader`
- **UI 组件**：共享设计系统，位于 `mobile/packages/ui/`（使用 `flutter widget-preview start` 预览）

### Machine Learning（`machine-learning/immich_ml/`）

基于 **FastAPI** 的 Python 服务，使用 **ONNX Runtime** 进行 AI 推理：

- CLIP 模型用于智能搜索（视觉/文本嵌入）
- 人脸检测与识别
- OCR（光学字符识别）
- 支持多种执行提供器：CPU（ONNX）、CUDA、OpenVINO、ARM NN、RKNN、ROCm

模型以 ONNX 格式加载一次并在请求间缓存。测试使用 pytest + pytest-asyncio。Lint 使用 ruff，类型检查使用 mypy。

### 插件系统

基于 Extism 的插件系统。插件是 WebAssembly 模块，可挂载到资产、相册或人物的生命周期中。`packages/plugin-sdk` 定义接口；`packages/plugin-core` 托管运行时。

### OpenAPI / SDK 生成

OpenAPI 规范从 Zod schema 和 `@nestjs/swagger` 装饰器自动生成。运行 `mise open-api`：
1. 构建插件和 server
2. Server 生成 `open-api/immich-openapi-specs.json`
3. `oazapfts` 从规范生成 TypeScript SDK（`packages/sdk/`）
4. `open-api/bin/generate-dart-sdk.sh` 生成 Dart SDK（`mobile/openapi/`）

**绝不要直接修改 `open-api/immich-openapi-specs.json`**——它是自动生成的。应修改 Controller/DTO 装饰器。

## 数据库 Schema 变更

修改 `server/src/schema/` 时：

1. 编辑 `server/src/schema/tables/*.table.ts` 中的表定义、`enums.ts` 中的枚举或 `functions.ts` 中的函数。
2. 运行 `mise //server:migrations generate <迁移名称>` 自动生成迁移文件。
3. 检查生成的迁移是否正确。
4. 将其移动到 `server/src/schema/migrations/`。
5. Server 重启时自动检测并应用新迁移。
6. 开发环境中撤销最近一次迁移：`mise //server:migrations revert`
7. 完全重置开发数据库 schema：`mise //server:schema-reset`（删除并重建 `public` schema，然后运行所有迁移）

**Schema 文件位置：**
- 表定义：`server/src/schema/tables/*.table.ts`（Kysely 表构建器）
- 迁移：`server/src/schema/migrations/*.ts`
- PostgreSQL 枚举：`server/src/schema/enums.ts`
- PostgreSQL 函数：`server/src/schema/functions.ts`
- 原始 SQL 查询：`server/src/queries/*.sql`

## 翻译（i18n）

- 所有翻译通过 [Weblate](https://hosted.weblate.org/projects/immich/immich/) 管理。不要直接修改 `i18n/*.json` 翻译文件（`i18n/en.json` 除外，它是源文件）。
- 添加新翻译键：先在 `i18n/en.json` 中添加键，然后运行 `mise //mobile:translation` 生成 Flutter 翻译文件。
- 使用 ICU message format（通过 `intl-messageformat`）。

## 测试

- **Server 单元测试**：Vitest，配置文件 `server/test/vitest.config.mjs`。文件位于 `server/src/**/*.spec.ts`。使用 SWC（`unplugin-swc`）快速转换。覆盖率目标：`cores/`、`services/`、`utils/`。
- **Server 中型测试**：Vitest，配置文件 `server/test/vitest.config.medium.mjs`。集成测试位于 `server/test/medium/specs/**/*.spec.ts`。可能使用 testcontainers 启动 PostgreSQL。
- **Web 测试**：Vitest + `@testing-library/svelte` + `happy-dom`。
- **E2E API 测试**：Vitest，针对运行中的 Docker Compose 环境。
- **E2E Web 测试**：Playwright，针对运行中的 Docker Compose 环境（项目：`web`、`maintenance`、`ui`）。
- **ML 测试**：pytest + pytest-asyncio。

## 关键约定

- **Zod 做验证**——Server 全局使用 `nestjs-zod`（非 class-validator/class-transformer）。`enum.ts` 中的枚举包含 Zod schema 用于 OpenAPI。
- **Kysely，非 ORM**——所有数据库访问通过 repository 执行来自 `queries/*.sql` 文件的原始 SQL。
- **使用自动生成的 SDK**——Web 通过 `@immich/sdk` 与 server 通信，绝不使用原始 `fetch`。
- **功能冻结**——共享/资产所有权及外部库功能已冻结。这些领域只接受简单的 bug 修复（参见 `CONTRIBUTING.md`）。
- **桶导出**——`services/index.ts` 和 `repositories/index.ts` 导出平铺数组，用于模块定义中的 DI 注册。
- **NestJS 导入**——使用 `src/` 前缀（如 `import { Foo } from 'src/services/foo.service'`）。
- **Web 导入**——使用 `$lib` 别名代替 `src/lib/`。
- **TypeScript 6.x**，strict 模式。
- **pnpm 11.x**、**Node 24.x**。
- **Lint/Format**：所有 TS 包使用 Prettier + ESLint。Server 使用 `eslint-plugin-unicorn`。Web 使用 `eslint-plugin-svelte` 和 `eslint-plugin-better-tailwindcss`。Mobile 使用 DCM（Dart Code Metrics）。Python 使用 ruff + mypy。
- **不要修改 `mise.lock`**，除非项目依赖确实需要更新。
- **PR 模板**：描述变更内容、测试步骤以及 LLM 的使用程度。

## Git 工作流

- 主分支：`main`
- 推荐使用 conventional commits
- PR 描述应遵循 `.github/pull_request_template.md`
- Mobile 版本号通过 `misc/release/pump-version.sh` 升级
- 项目不接受 AI 生成的 PR（参见 `CONTRIBUTING.md`）
- **Commit 署名**：Claude Code 的 commit 末尾必须使用 `Generated-by: Claude Code (deepseek-v4-pro)`，禁止使用 `Co-Authored-By`。
- **`mise.lock` 绝不能提交**——它是本地环境锁文件。每次提交前必须确认它不在暂存区中。

## 沟通（来自贡献指南）

开始开发一个功能前：
1. 在 [Discord](https://discord.immich.app) 的 `#contributing` 频道中讨论。
2. 确认该功能会被接受。
3. 询问推荐的实现方式。
4. 确保没有其他人已经在做同样的工作。
