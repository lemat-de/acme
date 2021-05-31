#!/usr/bin/env bash
set -eo pipefail

# Set the name of the certificate
CERT_NAME=$(echo "${DOMAINS}" | head -n1 | awk '{print $1;}')

# if nothing is set in ${DOMAINS} check ${WILDCARD_DOMAINS} for the first domain
if [[ -z "$CERT_NAME" ]]; then
    CERT_NAME=$(echo "${WILDCARD_DOMAINS}" | head -n1 | awk '{print $1;}')
    if [[ -z "$CERT_NAME" ]]; then
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
    if [[ "${ACME_STAGING}" = true ]]; then
        acme.sh --staging --renew --ocsp ${ACME_DOMAINS} --issue --dns "${DNS_API}" --config-home "${ACME_DIR}/bin" -k ec-256 --accountemail "${MAIL}" -ak 4096 || ACME_RETURN_CODE=$?
    else
        acme.sh --renew --ocsp ${ACME_DOMAINS} --issue --dns "${DNS_API}" --config-home "${ACME_DIR}/bin" -k ec-256 --accountemail "${MAIL}" -ak 4096 || ACME_RETURN_CODE=$?
    fi

    # If acme.sh returns code 2 then no renewal is needed
    if [[ ${ACME_RETURN_CODE} -ne 0 ]] && [ ${ACME_RETURN_CODE} -ne 2 ]; then
        exit ${ACME_RETURN_CODE}
    fi

    # put the certificates in the shared volumes
    cat "${ACME_DIR}/bin/${CERT_NAME}_ecc/fullchain.cer" "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.key" > "${CERT_DIR}/fullchain.pem"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.cer" "${CERT_DIR}/${CERT_NAME}.crt"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/ca.cer" "${CERT_DIR}/${CERT_NAME}.ca"
    cp "${ACME_DIR}/bin/${CERT_NAME}_ecc/${CERT_NAME}.key" "${CERT_DIR}/${CERT_NAME}.key"

    if [[ $OCSP_STAPLING = true ]]; then
        # The OCSP stapling code is based on this blogpost https://icicimov.github.io/blog/server/HAProxy-OCSP-stapling/ from Igor Cicimov

        echo "Starting OCSP updater"

        # Get the issuer URI, download it's certificate and convert into PEM format
        CERT="${CERT_DIR}/${CERT_NAME}.crt"
        ISSUER_URI=$(openssl x509 -in ${CERT} -text -noout | grep 'CA Issuers' | cut -d: -f2,3)
        ISSUER_NAME=$(echo ${ISSUER_URI##*/} | while read -r fname; do echo ${fname%.*}; done)
        wget -q -O- $ISSUER_URI | openssl x509 -inform DER -outform PEM -out ${CERT_DIR}/${ISSUER_NAME}.pem

        # Get the OCSP URL from the certificate
        ocsp_url=$(openssl x509 -noout -ocsp_uri -in ${CERT})

        # Extract the hostname from the OCSP URL
        ocsp_host=$(echo $ocsp_url | cut -d/ -f3)

        # Create/update the ocsp response file and update HAProxy
        openssl ocsp -noverify -no_nonce -issuer ${CERT_DIR}/${ISSUER_NAME}.pem -cert ${CERT} -url $ocsp_url -header Host $ocsp_host -respout ${CERT}.ocsp
        [[ $? -eq 0 ]] && [[ $(pidof haproxy) ]] && [[ -s ${CERT}.ocsp ]] \
        && echo "set ssl ocsp-response $(base64 -w 10000 ${CERT}.ocsp)" | socat stdio unix-connect:/run/haproxy/admin.sock
    fi

    # sleep for a day to check again next day
    echo "Going to sleep for a day"
    sleep 86400
done
