#!/usr/bin/env bash
set -eo pipefail

# Set the name of the certificate
CERT_NAME=$(echo "${DOMAINS}" | head -n1 | awk '{print $1;}')

# if nothing is set in ${DOMAINS} check ${WILDCARD_DOMAINS} for the first domain
if [ -z "$CERT_NAME" ]; then
    CERT_NAME=$(echo "${WILDCARD_DOMAINS}" | head -n1 | awk '{print $1;}')
    if [ -z "$CERT_NAME" ]; then
        echo "No domains found."
        echo "Exiting..."
        exit 1
    fi
fi

# check if the provided domains are FQDNs and string them together
for d in ${DOMAINS}; do
    if echo "$d" | grep -P "(?=^.{4,253}$)(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"; then
        ACME_DOMAINS="$ACME_DOMAINS -d $d"
    else
        echo "You need to use fully qualified domain names!"
        exit 1
    fi
done

# check if the provided domains are FQDNs and string them together
for w in ${WILDCARD_DOMAINS}; do
    if echo "$w" | grep -P "(?=^.{4,253}$)(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"; then
        ACME_DOMAINS="$ACME_DOMAINS -d $w -d *.$w"
    else
        echo "You need to use fully qualified domain names!"
        exit 1
    fi
done

# issue the certificate
while true; do
    ACME_RETURN_CODE=0    

    # if ${ACME_STAGING} is set to true use the letsencrypt staging environment
    if [ "${ACME_STAGING}" = true ]; then
        acme.sh --staging --renew --ocsp ${ACME_DOMAINS} --issue --dns "${DNS_API}" --config-home "${ACME_DIR}/bin" -k ec-256 --accountemail "${MAIL}" -ak 4096 || ACME_RETURN_CODE=$?
    else
        acme.sh --renew --ocsp ${ACME_DOMAINS} --issue --dns "${DNS_API}" --config-home "${ACME_DIR}/bin" -k ec-256 --accountemail "${MAIL}" -ak 4096 || ACME_RETURN_CODE=$?
    fi

    # If acme.sh returns code 2 then no renewal is needed
    if [ ${ACME_RETURN_CODE} -ne 0 ] && [ ${ACME_RETURN_CODE} -ne 2 ]; then
        exit ${ACME_RETURN_CODE}
    fi

    # put the certificates in the shared volumes
    cat "${ACME_DIR}/bin/${CERT_NAME}_ecc/fullchain.cer" "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.key" > "${CERT_DIR}/fullchain.pem"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.cer" "${CERT_DIR}/${CERT_NAME}.crt"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/ca.cer" "${CERT_DIR}/${CERT_NAME}.ca"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.key" "${CERT_DIR}/${CERT_NAME}.key"

    if [[ $OCSP_STAPLING = true ]]; then
        OCSP_FILE="${CERT_DIR}/${CERT_NAME}.crt.ocsp"
        CERT="${CERT_DIR}/${CERT_NAME}.crt"
        CHAIN="${CERT_DIR}/${CERT_NAME}.ca"

        echo "Starting OCSP updater"

        # get the uri from the certificate
        OCSP_URL=$(openssl x509 -noout -ocsp_uri -in "${CERT}")
        # Create/update the ocsp response file and update HAProxy
        openssl ocsp -no_nonce -issuer "${CHAIN}" -cert "${CERT}" -url "${OCSP_URL}" -respout "${OCSP_FILE}" \
        && ENCODED_RESPONSE=$(base64 -w 0 "${OCSP_FILE}") \
        && echo "set ssl ocsp-response ${ENCODED_RESPONSE}" | socat /run/haproxy/admin.sock stdio
    fi

    # sleep for a day to check again next day
    echo "Going to sleep for a day"
    sleep 86400
done
