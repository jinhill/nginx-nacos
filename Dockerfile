# ==========================================
# Stage 1: Builder (编译环境)
# ==========================================
FROM alpine:3.22 AS builder
RUN echo 'https://mirrors.cloud.tencent.com/alpine/v3.22/main' > /etc/apk/repositories \
    && echo 'https://mirrors.cloud.tencent.com/alpine/v3.22/community' >> /etc/apk/repositories
# 定义版本变量
ENV NGINX_VERSION=1.28.0
ENV NJS_VERSION=0.9.4
ENV NACOS_UPSTREAM_VERSION=v1.0.2

# 安装编译依赖 (这些包很大，只存在于 builder 阶段)
RUN apk add --no-cache \
    build-base \
    linux-headers \
    openssl-dev \
    pcre2-dev \
    zlib-dev \
    curl-dev \
    yajl-dev \
    libxml2-dev \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    bash \
    cmake

WORKDIR /usr/src

# 下载并解压源码
# 1. Nginx
RUN wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
    && tar -zxvf nginx-${NGINX_VERSION}.tar.gz

# 2. NJS (指定 Tag)
RUN wget -O njs-${NJS_VERSION}.tar.gz https://ghfast.top/https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz \
    && tar -zxvf njs-${NJS_VERSION}.tar.gz \
    && mv njs-${NJS_VERSION} njs

# 3. Nacos Upstream (指定 Tag)
RUN wget -O nacos-upstream-${NACOS_UPSTREAM_VERSION}.tar.gz https://ghfast.top/https://github.com/nacos-group/nginx-nacos-upstream/archive/refs/tags/${NACOS_UPSTREAM_VERSION}.tar.gz \
    && tar -zxvf nacos-upstream-${NACOS_UPSTREAM_VERSION}.tar.gz \
    && mv nginx-nacos-upstream* nginx-nacos-upstream

# 编译 Nginx
WORKDIR /usr/src/nginx-${NGINX_VERSION}

# 打补丁操作：将 nacos 模块的补丁应用到 Nginx 源码
RUN echo "Applying patch for nginx-nacos-upstream..." \
    && patch -p1 < ../nginx-nacos-upstream/patch/nginx.patch

# 注意：我们配置了 --prefix=/etc/nginx 和 --sbin-path=/usr/sbin/nginx
# 这样在第二阶段复制时路径比较清晰
RUN ./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-stream \
    --with-stream_ssl_module \
    --add-module=../njs/nginx \
    --add-module=../nginx-nacos-upstream/modules/auxiliary \
    --add-module=../nginx-nacos-upstream/modules/nacos \
    --with-cc-opt='-Os -fomit-frame-pointer' \
    --with-ld-opt='-Wl,--as-needed' \
    && make -j$(nproc) \
    && make install

# ==========================================
# Stage 2: Final (正式发布镜像)
# ==========================================
FROM alpine:3.22
RUN echo 'https://mirrors.cloud.tencent.com/alpine/v3.22/main' > /etc/apk/repositories \
    && echo 'https://mirrors.cloud.tencent.com/alpine/v3.22/community' >> /etc/apk/repositories
# 1. 创建用户
RUN addgroup -S nginx && adduser -S nginx -G nginx

# 2. 安装运行时依赖
# 注意：这里安装的是运行时库(如 libcurl)，而不是开发库(如 curl-dev)
# yajl 和 libcurl 是 nginx-nacos-upstream 必须的
RUN apk add --no-cache \
    openssl \
    pcre2 \
    zlib \
    libcurl \
    yajl \
    libxml2 \
    libxslt \
    gd \
    geoip \
    ca-certificates \
    tzdata

# 3. 从 Builder 阶段复制编译产物
# 复制二进制文件
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
# 复制配置文件目录
COPY --from=builder /etc/nginx /etc/nginx
# 复制模块目录 (如果编译了动态模块)
# COPY --from=builder /usr/lib/nginx/modules /usr/lib/nginx/modules

# 4. 创建必要的目录并修正权限
# 因为 COPY 过来的文件默认权限可能归属于 root，或者日志目录不存在
RUN mkdir -p /var/log/nginx /var/cache/nginx /var/run \
    && chown -R nginx:nginx /etc/nginx /var/log/nginx /var/cache/nginx /var/run \
    # 将日志重定向到标准输出/错误，符合 Docker 最佳实践
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

# 5. 设置工作目录和端口
WORKDIR /etc/nginx
EXPOSE 80 443

# 6. 停止信号
STOPSIGNAL SIGQUIT

# 7. 启动命令
CMD ["nginx", "-g", "daemon off;"]
