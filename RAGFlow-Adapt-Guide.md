# RAGFlow 适配指南
最小化改动适配 RAGFlow

## Git
Git 开发流程如下
### 1. 分支说明

```text
upstream/main   官方仓库
      ↓
origin/main     官方同步分支
      ↓
adapt           适配分支，仅修改这里
```
### 2. 操作说明
#### 1). 新环境准备（仅首次）
- 克隆代码
```shell
git clone https://github.com/maoxiaowang/ragflow.git
```

- 添加官方远端仓库
```shell
git remote add upstream https://github.com/infiniflow/ragflow.git
```

- 创建适配分支
```
git checkout -b adapt
```

#### 2). 日常更新

- 更新本地 upstream
```shell
git checkout main
git fetch upstream
```

- 更新 main 分支
```shell
git rebase upstream/main
```

- 推送 main 分支
```shell
git push origin main --force-with-lease
```
> ⚠️ main 分支只做同步，不在上面开发

#### 3). 更新 adapt 分支
- 更新 adapt 分支
```shell
git checkout adapt
git rebase main
```

- 提交代码（可选）
```shell
git add .
git commit -m "描述你的改动"
```

- 推送 adapt 分支
```shell
git push origin adapt --force-with-lease
```

## Docker 部署

### 1. 上传代码到服务器

### 2. 使用 docker-compose 部署
```shell
cd ragflow
docker-compose up -d --build
```