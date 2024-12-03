FROM oven/bun:1.1

ENV TEST_SERVER="http://localhost:8000"
ENV PRODUCTION_SERVER="https://app.example.com"
ENV HOMEPAGE_URL="https://example.com"
ENV COUCHDB_HOST="localhost"
ENV COUCHDB_PORT="5984"
ENV COUCHDB_SERVER="https://app.example.com/db"
ENV PUBLIC_KEY="{ \"keydata\": \"somedata\" }"
ENV SUPPORT_EMAIL="some@example.com"
ENV SUPPORT_URGENT_EMAIL="urgent@example.com"
ENV FRESHDESK_APPID=12341234
ENV BEAMER_APPID="myappidforbeamer"
ENV LOGROCKET_APPID="asdf/app-name"
ENV TESTIMONIAL_URL="https://testimonialdomain.example.com"
ENV DESKTOP_SERIAL_SALT="some salt string"
ENV DESKTOP_PURCHASE_URL="https://example.com/buy"
ENV DESKTOP_PURCHASE_SUCCESS_URL="https://example.com/success"
ENV STRIPE_PUBLIC_KEY="pk_test_123412341234"

WORKDIR /www/gingkowriter.com/client

RUN apt-get update && \
	apt-get install --yes build-essential python3 unzip && \
	apt-get clean && \
	rm -r --force /var/lib/apt/lists/*

COPY . .

RUN bun install

RUN mv config-example.js config.js

# watch:static
RUN cp --recursive src/static/. web/

# elm-watch
RUN bunx elm make src/elm/Main.elm --output web/elm.js

# watch:js
RUN bun esbuild.mjs

CMD bun run newwatch
