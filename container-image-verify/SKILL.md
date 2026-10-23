---
name: container-image-verify
slug: container-image-verify
version: 1.0.0
description: Verify a container image on any registry without Docker — whether a tag really exists, its arch/version/size, whether it is the genuine upstream image or a repackage, and whether it is anonymously pullable. Use when a CI build fails with "could not fetch content descriptor ... from remote: not found", when switching a base image to a domestic accelerator / cloud sync registry (docker.1ms.run, Huawei SWR ddn-k8s, daocloud ...), or when judging if a mirror can be trusted.
metadata: {"agent_created": true}
---

# 无 Docker 环境验证容器镜像来源与等价性

## 何时触发

- CI `docker build` 报 `httpReadSeeker: failed open: could not fetch content descriptor sha256:... from remote: not found`
- 要把基础镜像从 Docker Hub 换到国内加速站 / 云厂商同步仓库
- 怀疑某镜像「名字像官方、实际被重新打包过」
- 要确认某 tag 真实存在（而不是加速站对不存在的 tag 返回 latest）
- 要判断「改镜像源到底有没有生效」

## 三个 digest 各说明什么（先建立正确心智模型）

| 名称 | 取法 | 含义 |
|---|---|---|
| manifest digest | 响应头 `Docker-Content-Digest` | **外层包装**的哈希。多平台 index 与单架构 manifest 的 digest **天然不同**，不能直接比 |
| config digest | `manifest.config.digest` | 镜像配置（Env / Cmd / Entrypoint / Labels / architecture）的哈希 |
| layer digest[] | `manifest.layers[].digest` | 每层文件系统的哈希 |

**判定「内容等价」= config digest 相同 + 全部 layer digest 相同。** manifest digest 不同不代表内容不同。

## 铁律：层比对必须「同 tag + 同变体」

拿 A 镜像的 `latest`（可能是 Debian 版 1.27）去和 B 镜像的 `1.30.4-alpine` 逐层比对，**结论必然是"全不同"——但这是方法错误，不是镜像有问题**。版本不同、libc 变体（glibc/musl）不同，层当然全不一样。

正确顺序：
1. 先确认两边指向**同一版本 + 同一变体**（比 `manifest.config.digest` 最快）
2. config digest 相同 → 直接判定等价，无需再比层
3. config digest 不同 → 再逐层比 layer digest，判断差异范围

## 判真伪的两级方法

### 轻量：多源交叉（30 秒出结论）

拿 3~4 个**互相独立**的加速源拉同一个 tag 的 manifest digest：
**全部一致 → 这就是 Docker Hub 官方内容**（多个独立代理不可能巧合一致）。

再拉同仓库里**其它几个 tag** 一起看：
- 各 tag digest **互不相同** → tag 是真实的
- 所有 tag digest **一模一样** → 该站对不存在的 tag 做了 latest fallback，**结论无效**

### 严格：同 tag 同变体逐层比对（用于换源决策）

拉目标仓与一个可信代理（透明代理，digest 与官方一致）的同 tag manifest，比 config + layers。参考 `scripts/probe_image.py`。

## Registry HTTP API 流程（纯标准库即可）

```
1) GET  https://<host>/v2/                        → 401 + WWW-Authenticate: Bearer realm="...",service="..."
2) GET  <realm>?service=<svc>&scope=repository:<repo>:pull   → {"token": "..."}
3) GET  https://<host>/v2/<repo>/manifests/<tag>
      Headers: Accept: application/vnd.oci.image.index.v1+json,
               application/vnd.docker.distribution.manifest.list.v2+json,
               application/vnd.oci.image.manifest.v1+json,
               application/vnd.docker.distribution.manifest.v2+json
      Headers: Authorization: Bearer <token>
4) 若返回 index（有 manifests[]）→ 取 platform.os=linux & architecture=amd64 的 digest，再请求一次
5) GET  .../blobs/<config digest>                  → 读 architecture / created / Env / Cmd
```

要点：
- **step 1 的 realm 因站而异**，必须动态读，不要写死。已知值：Docker Hub `https://auth.docker.io/token`（service=`registry.docker.io`）；华为云 SWR `https://swr.cn-north-4.myhuaweicloud.com/swr/auth/v2/registry/auth/`（service=`dockyard`）
- 大多少加速站都支持**匿名 token**，无需 docker login → 顺手验证了「能否匿名拉取」

## 常见坑

1. **本机直连 `registry-1.docker.io` 可能被代理阻断**（`Tunnel connection failed: 502`），`WebFetch` 也可能失败 → 改用国内加速站当"读官方"的通道，多源交叉验证。
2. **单架构仓库**：部分同步仓库（华为云 `ddn-k8s/docker.io/*`）把多平台 index **拆成单架构 manifest**，arm64 版本另起 `*-linuxarm64` 后缀 tag。amd64 机器没问题，**arm64/farm 构建机不能用同一个 tag**。
3. **index 里会混有 `platform: unknown/unknown` 的条目**：那是 BuildKit 的 attestation（provenance/SBOM）子清单，正常现象，挑选 `linux/amd64` 时跳过即可。
4. **浮动 tag 不可靠**：这类仓库常缺 `mainline-alpine` 等浮动 tag，或同步滞后（如 `1.31.5` 只同步了 `-alpine3.24` 变体）。**必须写死具体版本号**。
5. **`latest` 可能是旧版本 + 另一个变体**：实测某仓库 `latest` 是 2024 年的 Debian 版 nginx 1.27.1（67.7MB），而同仓库 alpine 版只有 17~25MB。体积差 3 倍就是线索。
6. **别用 digests 判断"第三方重打包"就下结论** —— 见上面「铁律」。

## 换基础镜像源时的接线检查（极易漏）

`ARG NGINX_IMAGE=默认值` + CI 里 `docker build --build-arg NGINX_IMAGE=...` 的组合：
**`--build-arg` 会覆盖 Dockerfile 里的 ARG 默认值**，所以「只改了 Dockerfile 默认值」很可能压根不生效。

排查动作：**看构建命令（CI 脚本），不要只看 Dockerfile**。若两处都有默认值，必须同时改，并在两处都写注释互相提醒。

## 输出结论时建议给出的信息

- tag 是否存在、manifest 类型（index / 单架构 manifest）
- architecture、os、压缩体积、层数
- 镜像内组件版本与构建时间（config 的 `Env` / `created`）
- 与上游的等价性结论（config + 层比对结果）
- 是否匿名可拉
- 使用限制：必须写死版本号、arm64 不可用等
