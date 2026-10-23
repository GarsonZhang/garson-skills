---
name: minierp-project-structure
description: MINIERP project structure guide. Use when working in D:\Projects\MINIERP and needing orientation for the Vue/Vite front-end in mnerp-pc, the uni-app mobile front-end in mnerp_uniapp with its Android native shell in mnerp_android, or the ASP.NET Core back-end in mnerp-server — including where to find routes, views, requests, controllers, business services, models, table entities, permission manifests, startup/configuration, and build commands.
---

# MINIERP Project Structure

## Overview

Use this skill to orient quickly inside `D:\Projects\MINIERP`.

Read the project rules before changing anything: `AGENTS-Proj.md` (project-specific constraints, highest priority) and `CONTEXT.md` (current phase and current tasks). The root `AGENTS.md` holds personal working conventions.

## Workspace Map

- `mnerp-pc/`: Vue 3 desktop web front-end built with Vite and TypeScript.
- `mnerp_uniapp/`: uni-app + Vue 3 + TypeScript mobile front-end. Built to H5 and loaded by the Android shell.
- `mnerp_android/`: Android native shell for APK packaging, safe area, the WebView container, and APK online upgrade. It must not contain business pages or business API logic.
- `mnerp-server/`: ASP.NET Core back-end solution and related class libraries.
- `joc.efcore/`: framework source already referenced by `mnerp-server\MINIERP.sln`. Do not refactor framework internals unless the user explicitly asks.

## Front-End (mnerp-pc)

Start in `mnerp-pc`.

- `package.json`: scripts and dependencies. Common commands are `npm run dev`, `npm run build`, `npm run build-only`, `npm run type-check`, `npm run lint`, and `npm run format`.
- `vite.config.ts`: Vite configuration, `@` alias to `src`, Vue/JSX plugins, Sass setup, and Rollup chunk naming.
- `src/main.ts`: app bootstrap. Registers Pinia, router, Element Plus, VXE/VxeUI, global components, custom directives, relation-docs/SAP-task/dialog-table plugins, and initializes Axios.
- `src/App.vue`: root Vue component.
- `src/router/index.ts`: router creation, login route, root layout route, dynamic module routes loaded from `src/views/**/config.ts`, auth guard, user/cache/menu initialization.
- `src/router/baseRouters.ts`: static/base routes.
- `src/ajax/index.ts`: Axios instance. Base URL is `import.meta.env.VITE_APP_API_BASE_URL + '/api'`; request signing, token headers, refresh-token retry, error handling, and blob downloads live here.
- `src/request/`: per-module request helpers used by feature pages.
- `src/stores/`: Pinia stores such as `auth.ts`, `cacheData.ts`, and store initialization.
- `src/views/<module>/`: feature pages. Most modules follow `index.vue`, `request.ts`, `model.ts` or `models.ts`, `config.ts`, and optional dialog/drawer/components files.
- `src/components/`: shared Vue components such as layout/page wrappers, dialogs, select controls, import/export, relation docs, SAP sync task, and VXE helpers.
- `src/components/SelectorConfigs/`: front-end display configuration for unified selectors, plus `selectorCodes.ts`.
- `src/plugins/`: VXE renderers/edit renderers, theme tools, rules, number/dayjs helpers.
- `src/models/`: shared TypeScript models including API result/page/menu/auth/common-dictionary shapes.
- `src/directives/`: custom directives for permission, required fields, default images, select-all, and focus behavior.
- `src/utils/`, `src/libs/`, `src/icons/`, `src/assets/`: helpers, third-party wrappers, icon fonts, and static assets.
- `public/`: static assets, `web.config`, icon fonts, login images, menu images.

When adding or changing a front-end feature, usually inspect the matching folder under `src/views`, then its `request.ts`, `config.ts`, and any shared component/model it imports. Route discovery is convention-driven through `config.ts` files.

## Mobile (mnerp_uniapp + mnerp_android)

The mobile side is an "Android native shell + remote uni-app H5" pair. Business work and shell work are published separately.

- `mnerp_uniapp/src/pages/` and `src/pages.json`: mobile business pages and their route/component registration.
- `mnerp_uniapp/src/ajax/`, `src/stores/`, `src/models/`, `src/components/`, `src/styles/`, `src/utils/`, `src/static/`: the same layered conventions as the PC front-end, adapted to uni-app.
- `mnerp_uniapp/src/utils/nativeShell.ts`: caches the shell-injected `appVersion` / `appVersionCode` at startup. The login page and home page must read that cache only; they must not fall back to `mnerp_uniapp/manifest.json`.
- `mnerp_uniapp` commands: `npm run dev:app-android`, `npm run build:h5`, `npm run type-check`.
- `mnerp_android/manifest.json`: `versionName` and `versionCode` are the single source of truth for the client version. The shell reads the installed APK's real version through `plus.runtime.getProperty` and passes it to the WebView via `appVersion` / `appVersionCode` query parameters.
- `mnerp_android/config/app-update.config.js`: APK online-upgrade configuration (HTTPS update server, product id, version type). The update service must stay HTTPS.
- `mnerp_android/scripts/New-AndroidRelease.ps1`: Android release packaging script.
- `mnerp_android/hybrid/html/`: assets served inside the WebView container.
- Changing business pages, styles, or API interaction means rebuilding and publishing only the `mnerp_uniapp` H5. Native capability, shell upgrade, safe area, or WebView configuration changes require repackaging the `mnerp_android` APK.
- Query parameters are for display and diagnostics only and must never drive login, permission, upgrade eligibility, or other security decisions.

## Back-End (mnerp-server)

Start in `mnerp-server`.

- `MINIERP.sln`: the single back-end solution. It already includes both the application projects and the `joc.efcore` framework projects (`JOCAPI.Core`, `JOC.EFCore`, `JOC.EFCore.BulkExtensions`, `JOCAPI.Table.Core`, `JOC.MulitLingual`), so there is no separate "full" solution variant.
- `Nuget.config`: NuGet package source configuration.
- `permissions/`: YAML permission manifests at `permissions/modules/<moduleCode>/*.permission.yaml`. This is the only source of truth for permission definitions; the database stores role grants only.
- `JOCAPI.Start/`: ASP.NET Core web host and API surface.
- `JOCAPI.Start/Program.cs`: host builder. Configures logging defaults, ID helper, cache, data sources, dynamic assembly loading, hosted services, and Windows Service name.
- `JOCAPI.Start/Startup.cs`: service and middleware pipeline. Configures timezone, JWT/Basic auth policy scheme, NSwag OpenAPI, Newtonsoft JSON camel casing, global filters, SignalR, CORS, static files, initialization/request-id middleware, authentication/authorization, and controller routes.
- `JOCAPI.Start/appsettings*.json`: environment configuration and connection strings.
- `JOCAPI.Start/Controllers/`: API controllers. Important groups include business data, code generation, dictionary/dialog config, organization/role/user, report/file server, document numbers, and micro-app management.
- `JOCAPI.IBusiness/`: business interfaces such as `IDataOrderBusiness`, `IOrganizationBusiness`, `IUserLoginBusiness`, etc.
- `JOCAPI.Business/`: business implementations, base business helpers, data cache, document number generators, RabbitMQ providers, Quartz jobs, and feature-specific services.
- `JOCAPI.Business/Selectors/SelectorDescriptorRegistry.cs`: registry that every `selectorCode` must be declared in, each backed by an `ISelectorQueryHandler`.
- `JOCAPI.Models/`: request/response DTOs, common models, enums, approval/report/user/business/data-order/size/organization models.
- `JOCAPI.Table.ERP/`: ERP table entity classes such as `data_order`, `data_color`, `data_paichan`, `data_process`, and size/business-partner entities.
- `JOCAPI.DB.Migrations/`: database migration project.
- `JOCAPI.Logging.Serilog/`: logging integration.
- `JOCAPI.ReportPrint/`: report printing helpers/templates.
- `JOCAPI.Utils/`: utility helpers.
- `JOCAPI.BusinessTests/` and `JOCAPI.TestsCore/`: test projects.
- `Senparc/`: bundled WeChat/Senparc SDK projects used by the server.
- `Docs/`, `copyFiles/`, `release/`: in-repo docs, deployment copy inputs, and publish output. Keep publish output out of ordinary structure summaries.

Back-end feature flow is usually:

1. Controller action in `JOCAPI.Start/Controllers/**`.
2. Business interface in `JOCAPI.IBusiness`.
3. Business implementation in `JOCAPI.Business`.
4. DTOs/enums in `JOCAPI.Models`.
5. Table entity in `JOCAPI.Table.ERP` when persistence shape is relevant.

## Common Cross-Cut Patterns

- API routes are mapped with `/api/{controller}/{action}` plus a default controller/action route.
- Front-end requests usually pass paths relative to the Axios `/api` base, for example `/PCUser/getCurrentUser`.
- Front-end auth state and cached menus/permissions are loaded in the router guard via `auth` and `cacheData` stores.
- Dynamic front-end pages become routes through each feature's `src/views/**/config.ts`.
- Back-end responses are shaped by global filters including response formatting, exception handling, business-code initialization, signing checks, and DB API logging.
- Permission codes are shared verbatim between `mnerp-pc` and `mnerp_uniapp`. New interfaces must bind a permission code, and any permission-code change must also update `mnerp-server/permissions/display-order.yaml`.
- If a change touches both ends, search by feature name across `mnerp-pc/src/views`, `mnerp-pc/src/request`, `mnerp-server/JOCAPI.Start/Controllers`, `JOCAPI.IBusiness`, `JOCAPI.Business`, and `JOCAPI.Models`.

## Validation Hints

- Front-end: prefer `npm run type-check` or `npm run build` from `mnerp-pc` when TypeScript/Vue changes are made.
- Mobile: prefer `npm run type-check` from `mnerp_uniapp`. Rebuild the H5 (`npm run build:h5`) when business pages change.
- Back-end: prefer `dotnet build mnerp-server\MINIERP.sln` when C# changes are made.
- Selector changes: run `Validate-Selectors.ps1` after adding or changing a `selectorCode`.
- Keep validation scoped to the touched side unless the change crosses the API boundary.
