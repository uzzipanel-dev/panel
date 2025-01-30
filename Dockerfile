# syntax=docker.io/docker/dockerfile:1.7-labs
# UzziPanel Production Dockerfile

# ================================
# Stage 1: Build PHP Base Image
# ================================
FROM --platform=$TARGETOS/$TARGETARCH php:8.3-fpm-alpine AS base

ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

RUN install-php-extensions bcmath gd intl zip opcache pcntl posix pdo_mysql

RUN rm /usr/local/bin/install-php-extensions

# ================================
# Stage 2-1: Composer Install
# ================================
FROM --platform=$TARGETOS/$TARGETARCH base AS composer

WORKDIR /build

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# Copy bare minimum to install Composer dependencies
COPY composer.json composer.lock ./

RUN composer install --no-dev --no-interaction --no-autoloader --no-scripts

# ================================
# Stage 2-2: Yarn Install
# ================================
FROM --platform=$TARGETOS/$TARGETARCH node:20-alpine AS yarn

WORKDIR /build

# Copy bare minimum to install Yarn dependencies
COPY package.json yarn.lock ./

RUN yarn config set network-timeout 300000 \
    && yarn install --frozen-lockfile

# ================================
# Stage 3-1: Composer Optimize
# ================================
FROM --platform=$TARGETOS/$TARGETARCH composer AS composerbuild

# Copy full code to optimize autoload
COPY --exclude=Caddyfile --exclude=docker/ . ./

RUN composer dump-autoload --optimize

# ================================
# Stage 3-2: Build Frontend Assets
# ================================
FROM --platform=$TARGETOS/$TARGETARCH yarn AS yarnbuild

WORKDIR /build

# Copy full code
COPY --exclude=Caddyfile --exclude=docker/ . ./
COPY --from=composer /build .

RUN yarn run build

# ================================
# Stage 4: Build Final Application Image
# ================================
FROM --platform=$TARGETOS/$TARGETARCH base AS final

WORKDIR /var/www/html

# Install additional required libraries
RUN apk update && apk add --no-cache \
    caddy ca-certificates supervisor supercronic

COPY --chown=root:www-data --chmod=640 --from=composerbuild /build .
COPY --chown=root:www-data --chmod=640 --from=yarnbuild /build/public ./public

# Set permissions
# First ensure all files are owned by root and restrict www-data to read access
RUN chown root:www-data ./ \
    && chmod 750 ./ \
    # Files should not have execute set, but directories need it
    && find ./ -type d -exec chmod 750 {} \; \
    # Symlink to env/database path, as www-data won't be able to write to webroot
    && ln -s /uzzi-data/.env ./.env \
    && ln -s /uzzi-data/database/database.sqlite ./database/database.sqlite \
    # Create necessary directories
    && mkdir -p /uzzi-data /var/run/supervisord /etc/supercronic \
    # Finally allow www-data write permissions where necessary
    && chown -R www-data:www-data /uzzi-data ./storage ./bootstrap/cache /var/run/supervisord \
    && chmod -R u+rwX,g+rwX,o-rwx /uzzi-data ./storage ./bootstrap/cache /var/run/supervisord

# Configure Supervisor
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/Caddyfile /etc/caddy/Caddyfile
# Add Laravel scheduler to crontab
COPY docker/crontab /etc/supercronic/crontab

COPY docker/entrypoint.sh ./docker/entrypoint.sh

HEALTHCHECK --interval=5m --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/up || exit 1

EXPOSE 80 443

VOLUME /uzzi-data

USER www-data

ENTRYPOINT [ "/bin/ash", "docker/entrypoint.sh" ]
CMD [ "supervisord", "-n", "-c", "/etc/supervisord.conf" ]
