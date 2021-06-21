# elabftw + nginx + php-fpm in a container
FROM alpine:3.13

# select version or branch here
ARG ELABFTW_VERSION=4.0.0
ENV ELABFTW_VERSION $ELABFTW_VERSION

# this is versioning for the container image
ARG ELABIMG_VERSION=2.5.1
ENV ELABIMG_VERSION $ELABIMG_VERSION

ARG S6_OVERLAY_VERSION=2.2.0.1
ENV S6_OVERLAY_VERSION $S6_OVERLAY_VERSION

LABEL org.label-schema.name="elabftw" \
    org.label-schema.description="Run nginx and php-fpm to serve elabftw" \
    org.label-schema.url="https://www.elabftw.net" \
    org.label-schema.vcs-url="https://github.com/elabftw/elabimg" \
    org.label-schema.version=$ELABFTW_VERSION \
    org.label-schema.maintainer="nicolas.carpi@curie.fr" \
    org.label-schema.schema-version="1.0"

# install nginx and php-fpm
# php8-gd is required by mpdf for transparent png
# coreutils has sha384sum
# php8-tokenizer and php8-xmlwriter are for dev only
# don't put line comments inside this instruction
RUN apk upgrade -U -a && apk add --no-cache \
    bash \
    brotli \
    coreutils \
    curl \
    freetype \
    ghostscript \
    git \
    openssl \
    nginx \
    nginx-mod-http-brotli \
    openjdk11-jre \
    php8 \
    php8-curl \
    php8-ctype \
    php8-dev \
    php8-dom \
    php8-exif \
    php8-gd \
    php8-gettext \
    php8-fileinfo \
    php8-fpm \
    php8-json \
    php8-ldap \
    php8-mbstring \
    php8-opcache \
    php8-openssl \
    php8-pdo_mysql \
    php8-pear \
    php8-pecl-imagick \
    php8-phar \
    php8-redis \
    php8-session \
    php8-zip \
    php8-zlib \
    tzdata \
    unzip \
    yarn

# install s6-overlay, our init system. Workaround for different versions using TARGETPLATFORM
# platform see https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then ARCHITECTURE=amd64; elif [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then ARCHITECTURE=arm; elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then ARCHITECTURE=aarch64; else ARCHITECTURE=amd64; fi \
    && curl -sS -L -O --output-dir /tmp/ --create-dirs "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${ARCHITECTURE}.tar.gz" \
    && tar xzf "/tmp/s6-overlay-${ARCHITECTURE}.tar.gz" -C /

# add a symlink to php8
RUN ln -s /usr/bin/php8 /usr/bin/php

# clone elabftw repository in /elabftw
RUN git clone --depth 1 -b $ELABFTW_VERSION https://github.com/elabftw/elabftw.git /elabftw && chown -R nginx:nginx /elabftw && rm -rf /elabftw/.git

WORKDIR /elabftw

# install composer
RUN echo "$(curl -sS https://composer.github.io/installer.sig) -" > composer-setup.php.sig \
    && curl -sS https://getcomposer.org/installer | tee composer-setup.php | sha384sum -c composer-setup.php.sig \
    && php8 composer-setup.php && rm composer-setup.php*

# install dependencies
RUN /elabftw/composer.phar install --prefer-dist --no-progress --no-dev -a && yarn config set network-timeout 300000 && yarn install --pure-lockfile && yarn run buildall && rm -rf node_modules && yarn cache clean && /elabftw/composer.phar clear-cache

# redirect nginx logs to stout and stderr
RUN ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log && ln -sf /dev/stderr /var/log/php8/error.log 

# copy configuration and run script
COPY ./src/nginx/ /etc/nginx/
COPY ./src/run.sh /run.sh
COPY ./src/services /etc/services.d

RUN mkdir -p /sessions /etc/nginx/certs /ssl /elabftw/uploads /elabftw/cache
RUN chown nginx:nginx /sessions /etc/nginx/certs /ssl /elabftw/uploads /elabftw/cache

##
ENV PHP_CONFIGURATION_PATH=/etc/php8 \
    PHP_SESSIONS_PATH=/sessions \
    NGINX_SCRIPTS_PATH=/usr/share/nginx \
    NGINX_ROOT=/etc/nginx \
    ELABFTW_ROOT=/elabftw \
    APP_SCRIPT=/run.sh \
    APP_INIT_PATH=/etc/services.d

# In order to drop the root user, we have to make some directories world
# writeable as OpenShift default security model is to run the container under
# random UID.
RUN chmod -R a+rwX ${NGINX_ROOT} && \
    chmod -R a+rwX ${ELABFTW_ROOT} && \
    chmod -R a+rwX ${NGINX_SCRIPTS_PATH} && \
    chmod -R a+rwX ${PHP_CONFIGURATION_PATH} && \
    chmod -R a+rwX ${PHP_SESSIONS_PATH} && \
    chmod -R a+rwX ${APP_SCRIPT} && \
    chmod -R a+rwX ${APP_INIT_PATH}

#    chown -R 1001:0 ${NGINX_ROOT} && \
#    chown -R 1001:0 ${ELABFTW_ROOT} && \
#    chown -R 1001:0 ${NGINX_SCRIPTS_PATH} && \
#    chown -R 1001:0 ${APP_SCRIPT} && \
#    chown -R 1001:0 ${APP_INIT_PATH}

#USER 1001

EXPOSE 8080
EXPOSE 8443

# this script checks if nginx is ok
HEALTHCHECK --interval=2m --timeout=5s --retries=1 CMD sh /etc/nginx/healthcheck.sh

# start
CMD ["/run.sh"]

# define mountable directories
VOLUME /elabftw
VOLUME /ssl
VOLUME /mysql-cert
