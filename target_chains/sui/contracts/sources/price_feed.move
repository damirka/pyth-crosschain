module pyth::price_feed;

use pyth::price::Price;
use pyth::price_identifier::PriceIdentifier;

/// PriceFeed represents a current aggregate price for a particular product.
public struct PriceFeed has copy, drop, store {
    /// The price identifier
    price_identifier: PriceIdentifier,
    /// The current aggregate price
    price: Price,
    /// The current exponentially moving average aggregate price
    ema_price: Price,
}

public fun new(price_identifier: PriceIdentifier, price: Price, ema_price: Price): PriceFeed {
    PriceFeed {
        price_identifier,
        price,
        ema_price,
    }
}

public fun from(price_feed: &PriceFeed): PriceFeed {
    PriceFeed {
        price_identifier: price_feed.price_identifier,
        price: price_feed.price,
        ema_price: price_feed.ema_price,
    }
}

public use fun get_price_identifier as PriceFeed.price_identifier;

public fun get_price_identifier(price_feed: &PriceFeed): PriceIdentifier {
    price_feed.price_identifier
}

public use fun get_price as PriceFeed.price;

public fun get_price(price_feed: &PriceFeed): Price {
    price_feed.price
}

public use fun get_ema_price as PriceFeed.ema_price;

public fun get_ema_price(price_feed: &PriceFeed): Price {
    price_feed.ema_price
}
