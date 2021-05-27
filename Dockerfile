FROM alpine:latest

ARG ACME_VER=2.8.9
ARG ACME_SHA256=2b341453da63235a8a4c1649bff1a197f27ee84c7c36d8ff98b3aed261f62524

ENV USER=acme \
	ACME_DIR=/acme \
	PATH="${ACME_DIR}/bin:${PATH}" \
	CERT_DIR=/letsencrypt \
	HAPROXY_SOCKET_DIR=/run/haproxy \
    HAPROXY_SOCKET=/run/haproxy/admin.sock

RUN set -ex \
    && apk add --no-cache coreutils bash wget tar grep acl socat openssl tini \
    && adduser -D -u 99 -h "${ACME_DIR}" "${USER}" \
    && sed -i 's/\/bin\/ash/\/bin\/bash/g' /etc/passwd \
    && cd "${ACME_DIR}" \
    && wget "https://github.com/acmesh-official/acme.sh/archive/${ACME_VER}.tar.gz" -O "${ACME_VER}.tar.gz" \
    && echo "${ACME_SHA256}  ${ACME_VER}.tar.gz" | sha256sum -c - \
    && mkdir -p "${ACME_DIR}/bin" \
    && tar xf ${ACME_VER}.tar.gz -C bin --strip-components 1 \
    && rm ${ACME_VER}.tar.gz \
    && chown -R 99:99 "${ACME_DIR}" \
    && chmod 700 "${ACME_DIR}" \
    && mkdir "${CERT_DIR}" \
    && chown 99:99 "${CERT_DIR}" \
    && chmod 755 "${CERT_DIR}" \
    && mkdir -p ${HAPROXY_SOCKET_DIR} \
    && chown 99:99 ${HAPROXY_SOCKET_DIR}

ADD entrypoint.sh /entrypoint.sh

USER "${USER}"
ENV PATH="${ACME_DIR}/bin:${PATH}"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
