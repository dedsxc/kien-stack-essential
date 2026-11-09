# Changelog

## [0.3.0](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.4...v0.3.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* expose apps with Gateway API (HTTPRoute) instead of Ingress ([#15](https://github.com/dedsxc/kien-stack-essential/issues/15))

### Features

* expose apps with Gateway API (HTTPRoute) instead of Ingress ([#15](https://github.com/dedsxc/kien-stack-essential/issues/15)) ([db040f7](https://github.com/dedsxc/kien-stack-essential/commit/db040f7309994c47ea6e763bcb5ae75f46108004))

## [0.2.4](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.3...v0.2.4) (2026-11-08)


### Bug fixes

* values carry no global defaults, cluster.yaml provides them ([#13](https://github.com/dedsxc/kien-stack-essential/issues/13)) ([32817b7](https://github.com/dedsxc/kien-stack-essential/commit/32817b74df56d10d081f81a6e969de8782bfe157))

## [0.2.3](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.2...v0.2.3) (2026-11-08)


### Bug fixes

* **install:** retry chart downloads, silence tr broken pipe ([#10](https://github.com/dedsxc/kien-stack-essential/issues/10)) ([ee4b9c5](https://github.com/dedsxc/kien-stack-essential/commit/ee4b9c508b254df5e472f10cbb5800940657aa77))

## [0.2.2](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.1...v0.2.2) (2026-11-08)


### Features

* app Postgres via cnpg-cluster chart, password ClusterGenerator, Reloader brick ([#4](https://github.com/dedsxc/kien-stack-essential/issues/4)) ([a0af69f](https://github.com/dedsxc/kien-stack-essential/commit/a0af69f0ffc5ccba4bd1f889f99904181dd23b87))
