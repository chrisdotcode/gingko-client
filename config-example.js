import * as env from 'env';

module.exports = {
  TEST_SERVER: env.TEST_SERVER,
  PRODUCTION_SERVER: env.PRODUCTION_SERVER,
  HOMEPAGE_URL: env.HOMEPAGE_URL,
  COUCHDB_HOST: env.COUCHDB_HOST,
  COUCHDB_PORT: env.COUCHDB_PORT,
  COUCHDB_SERVER: env.COUCHDB_SERVER,
  PUBLIC_KEY: JSON.parse(env.PUBLIC_KEY),
  SUPPORT_EMAIL: env.SUPPORT_EMAIL,
  SUPPORT_URGENT_EMAIL: env.SUPPORT_URGENT_EMAIL,
  FRESHDESK_APPID: env.FRESHDESK_APPID,
  BEAMER_APPID: env.BEAMER_APPID,
  LOGROCKET_APPID: env.LOGROCKET_APPID,
  TESTIMONIAL_URL: env.TESTIMONIAL_URL,
  DESKTOP_SERIAL_SALT: env.DESKTOP_SERIAL_SALT,
  DESKTOP_PURCHASE_URL: env.DESKTOP_PURCHASE_SUCCESS_URL,
  DESKTOP_PURCHASE_SUCCESS_URL: env.STRIPE_PUBLIC_KEY,
  STRIPE_PUBLIC_KEY: env.STRIPE_PUBLIC_KEY,
  PRICE_DATA:
    { USD:
      { monthly:
        { discount: "price_id_234234"
        , regular: "price_id_12341234"
        , bonus: "price_id_542543"
        }
      , yearly:
        { discount: "price_id_1234"
        , regular: "price_id_1234"
        , bonus: "price_id_1234"
        }
      }
    , etc:
      { monthly:
        { discount: "price_1234"
        , regular: "price_1234"
        , bonus: "price_1234"
        }
      , yearly:
        { discount: "price_1234"
        , regular: "price_1234"
        , bonus: "price_1234"
        }
      }
   }
};
