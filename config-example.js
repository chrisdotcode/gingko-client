module.exports = {
  TEST_SERVER: process.env.TEST_SERVER,
  PRODUCTION_SERVER: process.env.PRODUCTION_SERVER,
  HOMEPAGE_URL: process.env.HOMEPAGE_URL,
  COUCHDB_HOST: process.env.COUCHDB_HOST,
  COUCHDB_PORT: process.env.COUCHDB_PORT,
  COUCHDB_SERVER: process.env.COUCHDB_SERVER,
  PUBLIC_KEY: process.env.PUBLIC_KEY,
  SUPPORT_EMAIL: process.env.SUPPORT_EMAIL,
  SUPPORT_URGENT_EMAIL: process.env.SUPPORT_URGENT_EMAIL,
  FRESHDESK_APPID: process.env.FRESHDESK_APPID,
  BEAMER_APPID: process.env.BEAMER_APPID,
  LOGROCKET_APPID: process.env.LOGROCKET_APPID,
  TESTIMONIAL_URL: process.env.TESTIMONIAL_URL,
  DESKTOP_SERIAL_SALT: process.env.DESKTOP_SERIAL_SALT,
  DESKTOP_PURCHASE_URL: process.env.DESKTOP_PURCHASE_SUCCESS_URL,
  DESKTOP_PURCHASE_SUCCESS_URL: process.env.STRIPE_PUBLIC_KEY,
  STRIPE_PUBLIC_KEY: process.env.STRIPE_PUBLIC_KEY,
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
