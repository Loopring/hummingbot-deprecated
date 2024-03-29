import aiohttp
import asyncio
import binascii
import json
import time
import uuid
import traceback
import urllib
import hashlib
from typing import (
    Any,
    Dict,
    List,
    Optional
)
import math
import logging
from decimal import *
from libc.stdint cimport int64_t
from hummingbot.core.data_type.cancellation_result import CancellationResult
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.data_type.order_book cimport OrderBook
from hummingbot.core.data_type.order_book_tracker import OrderBookTrackerDataSourceType
from hummingbot.market.market_base cimport MarketBase
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.wallet.ethereum.web3_wallet import Web3Wallet
from hummingbot.market.loopring.loopring_auth import LoopringAuth
from hummingbot.market.loopring.loopring_order_book_tracker import LoopringOrderBookTracker
from hummingbot.market.loopring.loopring_api_order_book_data_source import LoopringAPIOrderBookDataSource
from hummingbot.market.loopring.loopring_api_token_configuration_data_source import LoopringAPITokenConfigurationDataSource
from hummingbot.core.utils.async_utils import (
    safe_ensure_future,
)
from hummingbot.core.event.events import (
    MarketEvent,
    BuyOrderCompletedEvent,
    SellOrderCompletedEvent,
    OrderCancelledEvent,
    OrderExpiredEvent,
    OrderFilledEvent,
    MarketOrderFailureEvent,
    BuyOrderCreatedEvent,
    SellOrderCreatedEvent,
    TradeType,
    OrderType,
    TradeFee,
)
from hummingbot.logger import HummingbotLogger
from hummingbot.market.loopring.loopring_in_flight_order cimport LoopringInFlightOrder
from hummingbot.market.trading_rule cimport TradingRule
from hummingbot.core.utils.estimate_fee import estimate_fee
from hummingbot.core.utils.tracking_nonce import get_tracking_nonce

from hummingbot.market.loopring.ethsnarks2.eddsa import PureEdDSA, PoseidonEdDSA
from hummingbot.market.loopring.ethsnarks2.field import FQ, SNARK_SCALAR_FIELD
from hummingbot.market.loopring.ethsnarks2.poseidon import poseidon_params, poseidon

s_logger = None
s_decimal_0 = Decimal(0)


def num_d(amount):
    return abs(Decimal(amount).normalize().as_tuple().exponent)

def now():
    return int(time.time()) * 1000


BUY_ORDER_COMPLETED_EVENT = MarketEvent.BuyOrderCompleted.value
SELL_ORDER_COMPLETED_EVENT = MarketEvent.SellOrderCompleted.value
ORDER_CANCELLED_EVENT = MarketEvent.OrderCancelled.value
ORDER_EXPIRED_EVENT = MarketEvent.OrderExpired.value
ORDER_FILLED_EVENT = MarketEvent.OrderFilled.value
ORDER_FAILURE_EVENT = MarketEvent.OrderFailure.value
BUY_ORDER_CREATED_EVENT = MarketEvent.BuyOrderCreated.value
SELL_ORDER_CREATED_EVENT = MarketEvent.SellOrderCreated.value
API_CALL_TIMEOUT = 10.0

# ==========================================================

GET_ORDER_ROUTE = "/api/v2/order"
MAINNET_API_REST_ENDPOINT = "https://api.loopring.io/"
MAINNET_WS_ENDPOINT = "wss://ws.loopring.io/v2/ws"
EXCHANGE_INFO_ROUTE = "api/v2/timestamp"
BALANCES_INFO_ROUTE = "api/v2/user/balances"
ACCOUNT_INFO_ROUTE = "api/v2/account"
MARKETS_INFO_ROUTE = "api/v2/exchange/markets"
TOKENS_INFO_ROUTE = "api/v2/exchange/tokens"
NEXT_ORDER_ID = "api/v2/orderId"
ORDER_ROUTE = "api/v2/order"
ORDER_CANCEL_ROUTE = "api/v2/orders"
MAXIMUM_FILL_COUNT = 16

cdef class LoopringMarketTransactionTracker(TransactionTracker):
    cdef:
        LoopringMarket _owner

    def __init__(self, owner: LoopringMarket):
        super().__init__()
        self._owner = owner

    cdef c_did_timeout_tx(self, str tx_id):
        TransactionTracker.c_did_timeout_tx(self, tx_id)
        self._owner.c_did_timeout_tx(tx_id)

cdef class LoopringMarket(MarketBase):
    # This causes it to hang when starting network
    @classmethod
    def logger(cls) -> HummingbotLogger:
        global s_logger
        if s_logger is None:
            s_logger = logging.getLogger(__name__)
        return s_logger

    def __init__(self,
                 loopring_accountid: int,
                 loopring_exchangeid: int,
                 loopring_private_key: str,
                 loopring_api_key: str,
                 poll_interval: float = 10.0,
                 order_book_tracker_data_source_type: OrderBookTrackerDataSourceType = OrderBookTrackerDataSourceType.EXCHANGE_API,
                 trading_pairs: Optional[List[str]] = None,
                 trading_required: bool = True):

        super().__init__()

        self._loopring_auth = LoopringAuth(loopring_api_key)
        self._token_configuration = LoopringAPITokenConfigurationDataSource()

        self.API_REST_ENDPOINT = MAINNET_API_REST_ENDPOINT
        self.WS_ENDPOINT = MAINNET_WS_ENDPOINT
        self._order_book_tracker = LoopringOrderBookTracker(
            data_source_type=order_book_tracker_data_source_type,
            trading_pairs=trading_pairs,
            rest_api_url=self.API_REST_ENDPOINT,
            websocket_url=self.WS_ENDPOINT,
            token_configuration = self._token_configuration
        )
        self._tx_tracker = LoopringMarketTransactionTracker(self)
        self._trading_required = trading_required
        self._poll_notifier = asyncio.Event()
        self._last_timestamp = 0
        self._poll_interval = poll_interval
        self._shared_client = None
        self._polling_update_task = None

        self._loopring_accountid = int(loopring_accountid)
        self._loopring_exchangeid = int(loopring_exchangeid)
        self._loopring_private_key = loopring_private_key

        # State
        self._lock = asyncio.Lock()
        self._trading_rules = {}
        self._pending_approval_tx_hashes = set()
        self._in_flight_orders = {}
        self._next_order_id = {}
        self._trading_pairs = trading_pairs
        self._order_sign_param = poseidon_params(SNARK_SCALAR_FIELD, 14, 6, 53, b'poseidon', 5, security_target=128)

        self._order_id_lock = asyncio.Lock()

    @property
    def name(self) -> str:
        return "loopring"

    @property
    def ready(self) -> bool:
        return all(self.status_dict.values())

    @property
    def status_dict(self) -> Dict[str, bool]:
        return {
            "order_books_initialized": len(self._order_book_tracker.order_books) > 0,
            "account_balances": len(self._account_balances) > 0 if self._trading_required else True,
            "trading_rule_initialized": len(self._trading_rules) > 0 if self._trading_required else True,
        }

    @property
    def token_configuration(self) -> LoopringAPITokenConfigurationDataSource:
        return self._token_configuration

    # ----------------------------------------
    # Markets & Order Books

    @property
    def order_books(self) -> Dict[str, OrderBook]:
        return self._order_book_tracker.order_books

    cdef OrderBook c_get_order_book(self, str trading_pair):
        cdef dict order_books = self._order_book_tracker.order_books
        if trading_pair not in order_books:
            raise ValueError(f"No order book exists for '{trading_pair}'.")
        return order_books[trading_pair]

    @property
    def limit_orders(self) -> List[LimitOrder]:
        cdef:
            list retval = []
            LoopringInFlightOrder loopring_flight_order

        for in_flight_order in self._in_flight_orders.values():
            loopring_flight_order = in_flight_order
            if loopring_flight_order.order_type is OrderType.LIMIT:
                retval.append(loopring_flight_order.to_limit_order())
        return retval

    async def get_active_exchange_markets(self) -> pd.DataFrame:
        return await LoopringAPIOrderBookDataSource.get_active_exchange_markets()

    # ----------------------------------------
    # Account Balances

    cdef object c_get_balance(self, str currency):
        return self._account_balances[currency]

    cdef object c_get_available_balance(self, str currency):
        return self._account_available_balances[currency]

    # ==========================================================
    # Order Submission
    # ----------------------------------------------------------

    async def _get_next_order_id(self, token, force_sync = False):
        async with self._order_id_lock:
            if force_sync or self._next_order_id.get(token) is None:
                try:
                    temp = await self.api_request("GET", NEXT_ORDER_ID, params={"accountId":self._loopring_accountid, "tokenSId": token})
                    next_id = temp["data"]
                    self._next_order_id[token] = next_id
                except Exception as e:
                    self.logger().info(str(e))
                    self.logger().info("Error getting the next order id from Loopring")
            else:
                next_id = self._next_order_id[token] 
                self._next_order_id[token] = next_id + 1

        return next_id
    
    async def _serialize_order(self, order):
        return [
            int(order["exchangeId"]),
            int(order["orderId"]),
            int(order["accountId"]),
            int(order["tokenSId"]),
            int(order["tokenBId"]),
            int(order["amountS"]),
            int(order["amountB"]),
            int(order["allOrNone"] == 'true'),
            int(order["validSince"]),
            int(order["validUntil"]),
            int(order["maxFeeBips"]),
            int(order["buy"] == 'true'),            
            int(order["label"])
        ]
        
    async def place_order(self,
                          client_order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          is_buy: bool,
                          order_type: OrderType,
                          price: Decimal) -> Dict[str, Any]:
        order_side : TradeType = TradeType.BUY if is_buy else TradeType.SELL
        base, quote = trading_pair.split('-')
        baseid, quoteid = self._token_configuration.get_tokenid(base), self._token_configuration.get_tokenid(quote)

        validSince = int(time.time()) - 3600
        order_details = self._token_configuration.sell_buy_amounts(baseid, quoteid, amount, price, order_side)
        token_s_id : int = order_details["tokenSId"]
        order_id = await self._get_next_order_id(token_s_id)
        order = {
            "exchangeId" : self._loopring_exchangeid,
            "orderId" : order_id,
            "accountId" : self._loopring_accountid,
            "allOrNone" : "false",
            "validSince" : validSince,
            "validUntil" : validSince + (604800*5), # Until week later
            "maxFeeBips" : 63,
            "label" : 20,
            "buy" : "true" if order_side is TradeType.BUY else "false",
            "clientOrderId" : client_order_id,
            **order_details
        }

        serialized_message = await self._serialize_order(order)
        msgHash = poseidon(serialized_message, self._order_sign_param)
        fq_obj = FQ(int(self._loopring_private_key))
        signed_message = PoseidonEdDSA.sign(msgHash, fq_obj)

        # Update with signature
        order.update({
            "hash"        : str(msgHash),
            "signatureRx" : str(signed_message.sig.R.x),
            "signatureRy" : str(signed_message.sig.R.y),
            "signatureS"  : str(signed_message.sig.s)
        })

        return await self.api_request("POST", ORDER_ROUTE, params=order, data=order)

    async def execute_order(self, order_side, client_order_id, trading_pair, amount, order_type, price):
        """
        Completes the common tasks from execute_buy and execute_sell.  Quantizes the order's amount and price, and 
        validates the order against the trading rules before placing this order.
        """
        # Quantize order    
        amount = self.c_quantize_order_amount(trading_pair, amount)
        price = self.c_quantize_order_price(trading_pair, price)

        # Check trading rules
        trading_rule = self._trading_rules[trading_pair]
        if order_type == OrderType.LIMIT and trading_rule.supports_limit_orders is False:
            raise ValueError("LIMIT orders are not supported")
        elif order_type == OrderType.MARKET and trading_rule.supports_market_orders is False:
            raise ValueError("MARKET orders are not supported")

        if amount < trading_rule.min_order_size:
            raise ValueError(f"Order amount({str(amount)}) is less than the minimum allowable amount({str(trading_rule.min_order_size)})")
        if amount > trading_rule.max_order_size:
            raise ValueError(f"Order amount({str(amount)}) is greater than the maximum allowable amount({str(trading_rule.max_order_size)})")
        if amount*price < trading_rule.min_notional_size:
            raise ValueError(f"Order notional value({str(amount*price)}) is less than the minimum allowable notional value for an order ({str(trading_rule.min_notional_size)})")

        try:
            created_at : int = int(time.time())
            creation_response = await self.place_order(client_order_id, trading_pair, amount, order_side is TradeType.BUY, order_type, price)
            
            # Verify the response from the exchange
            if "data" not in creation_response.keys():
                raise Exception(creation_response['resultInfo']['message'])
            loopring_order = creation_response["data"]

            # Begin tracking order
            in_flight_order = LoopringInFlightOrder.from_loopring_order(self, order_side, client_order_id, created_at, loopring_order, trading_pair, price, amount)
            self.start_tracking(in_flight_order)
            self.logger().info(
                f"Created {in_flight_order.description} order {client_order_id} for {amount} {trading_pair}.")

        except Exception as e:
            self.logger().warning(f"Error submitting {order_side.name} {order_type.name} order to Loopring for "
                               f"{amount} {trading_pair} at {price}.")
            self.logger().info(e)
            traceback.print_exc()

            # Re-sync our next order id after this failure
            base, quote = trading_pair.split('-')
            token_sell_id = self._token_configuration.get_tokenid(base) if order_side is TradeType.SELL else self._token_configuration.get_tokenid(quote)
            await self._get_next_order_id(token_sell_id, force_sync = True)

            # Stop tracking this order
            self.stop_tracking(client_order_id)
            self.c_trigger_event(ORDER_FAILURE_EVENT, MarketOrderFailureEvent(now(), client_order_id, order_type))

    async def execute_buy(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          order_type: OrderType,
                          price: Optional[Decimal] = Decimal('NaN')):
        try:
            await self.execute_order(TradeType.BUY, order_id, trading_pair, amount, order_type, price)
        
            self.c_trigger_event(BUY_ORDER_CREATED_EVENT, 
                                BuyOrderCreatedEvent(now(), order_type, trading_pair, Decimal(amount), Decimal(price), order_id))
        except ValueError as e:
            # Stop tracking this order
            self.stop_tracking(order_id)
            self.c_trigger_event(ORDER_FAILURE_EVENT, MarketOrderFailureEvent(now(), order_id, order_type))
            raise e

    async def execute_sell(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          order_type: OrderType,
                          price: Optional[Decimal] = Decimal('NaN')):
        try:
            await self.execute_order(TradeType.SELL, order_id, trading_pair, amount, order_type, price)
            self.c_trigger_event(SELL_ORDER_CREATED_EVENT, 
                                SellOrderCreatedEvent(now(), order_type, trading_pair, Decimal(amount), Decimal(price), order_id))
        except ValueError as e:
            # Stop tracking this order
            self.stop_tracking(order_id)
            self.c_trigger_event(ORDER_FAILURE_EVENT, MarketOrderFailureEvent(now(), order_id, order_type))
            raise e

    cdef str c_buy(self, str trading_pair, object amount, object order_type = OrderType.LIMIT, object price = 0.0,
                   dict kwargs = {}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str client_order_id = str(f"buy-{trading_pair}-{tracking_nonce}")
        safe_ensure_future(self.execute_buy(client_order_id, trading_pair, amount, order_type, price))
        return client_order_id

    cdef str c_sell(self, str trading_pair, object amount, object order_type = OrderType.LIMIT, object price = 0.0,
                    dict kwargs = {}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str client_order_id = str(f"sell-{trading_pair}-{tracking_nonce}")
        safe_ensure_future(self.execute_sell(client_order_id, trading_pair, amount, order_type, price))
        return client_order_id

    # ----------------------------------------
    # Cancellation

    async def cancel_order(self, client_order_id: str):
        in_flight_order = self._in_flight_orders.get(client_order_id)
        cancellation_event = OrderCancelledEvent(now(), client_order_id)

        if in_flight_order is None:
            self.c_trigger_event(ORDER_CANCELLED_EVENT, cancellation_event)
            return

        try:
            cancellation_payload = {
                "accountId": self._loopring_accountid,
                "clientOrderId": client_order_id
            }

            res = await self.api_request("DELETE", ORDER_CANCEL_ROUTE, params=cancellation_payload, secure=True)

            self.logger().info(f"Successfully cancelled order {client_order_id}")
            self.stop_tracking(client_order_id)
            self.c_trigger_event(ORDER_CANCELLED_EVENT, cancellation_event)

        except Exception as e:
            self.logger().info(f"Failed to cancel order {client_order_id}")
            self.logger().debug(e)

    cdef c_cancel(self, str trading_pair, str client_order_id):
        safe_ensure_future(self.cancel_order(client_order_id))

    cdef c_stop_tracking_order(self, str order_id):
        if order_id in self._in_flight_orders:
            del self._in_flight_orders[order_id]

    async def cancel_all(self, timeout_seconds: float) -> List[CancellationResult]:
        results = []
        cancellation_queue = self._in_flight_orders.copy()
        for order_id, in_flight in cancellation_queue.iteritems():
            try:
                await self.cancel_order(order_id)
                results.append(CancellationResult(order_id=order_id, success=True))
            except Exception:
                results.append(CancellationResult(order_id=order_id, success=False))
        return results


    cdef object c_get_fee(self,
                          str base_currency,
                          str quote_currency,
                          object order_type,
                          object order_side,
                          object amount,
                          object price):
        is_maker = order_type is OrderType.LIMIT
        return estimate_fee("loopring", is_maker)

    cdef object c_get_price(self, str trading_pair, bint is_buy):
        cdef OrderBook order_book = self.c_get_order_book(trading_pair)
        return Decimal(order_book.c_get_price(is_buy))

    # ==========================================================
    # Runtime
    # ----------------------------------------------------------

    async def start_network(self):
        await self.stop_network()
        await self._token_configuration._configure()
        self._order_book_tracker.start()

        if self._trading_required:
            exchange_info = await self.api_request("GET", EXCHANGE_INFO_ROUTE)
            
            for token in self._token_configuration.get_tokens():
                await self._get_next_order_id(token, force_sync = True)

        self._polling_update_task = safe_ensure_future(self._polling_update())

    async def stop_network(self):
        self._order_book_tracker.stop()
        self._pending_approval_tx_hashes.clear()
        self._polling_update_task = None

    async def check_network(self) -> NetworkStatus:
        try:
            await self.api_request("GET", EXCHANGE_INFO_ROUTE)
        except asyncio.CancelledError:
            raise
        except Exception:
            return NetworkStatus.NOT_CONNECTED
        return NetworkStatus.CONNECTED

    # ----------------------------------------
    # State Management

    @property
    def tracking_states(self) -> Dict[str, any]:
        return {
            key: value.to_json()
            for key, value in self._in_flight_orders.items()
        }

    def restore_tracking_states(self, saved_states: Dict[str, any]):
        for order_id, in_flight_json in saved_states.iteritems():
            self._in_flight_orders[order_id] = LoopringInFlightOrder.from_json(in_flight_json, self)

    def start_tracking(self, in_flight_order):
        self._in_flight_orders[in_flight_order.client_order_id] = in_flight_order

    def stop_tracking(self, client_order_id):
        if client_order_id in self._in_flight_orders:
            del self._in_flight_orders[client_order_id]


    # ----------------------------------------
    # updates to orders and balances

    def _update_inflight_order(self, tracked_order : LoopringInFlightOrder, event : Dict[str, Any]):
        issuable_events : List[MarketEvent] = tracked_order.update(event)

        # Issue relevent events
        for (market_event, new_amount, new_price, new_fee) in issuable_events:
            if market_event == MarketEvent.OrderCancelled:
                self.c_trigger_event(ORDER_CANCELLED_EVENT,
                                OrderCancelledEvent(self._current_timestamp,
                                                    client_order_id))
            elif market_event == MarketEvent.OrderFilled:
                self.c_trigger_event(ORDER_FILLED_EVENT,
                                    OrderFilledEvent(self._current_timestamp,
                                                    tracked_order.client_order_id,
                                                    tracked_order.trading_pair,
                                                    tracked_order.trade_type,
                                                    tracked_order.order_type,
                                                    new_price,
                                                    new_amount,
                                                    TradeFee(Decimal(0), [(tracked_order.quote_asset, new_fee)]),
                                                    tracked_order.client_order_id))
            elif market_event == MarketEvent.OrderExpired:
                self.c_trigger_event(ORDER_EXPIRED_EVENT,
                                OrderExpiredEvent(self._current_timestamp,
                                                    tracked_order.client_order_id))
            elif market_event == MarketEvent.OrderFailure:
                self.c_trigger_event(ORDER_FAILURE_EVENT,
                                MarketOrderFailureEvent(self._current_timestamp,
                                                    tracked_order.client_order_id,
                                                    tracked_order.order_type))

            # Complete the order if relevent
            if tracked_order.is_done:
                if not tracked_order.is_failure:
                    if tracked_order.trade_type is TradeType.BUY:
                        self.logger().info(f"The market buy order {tracked_order.client_order_id} has completed "
                                            f"according to user stream.")
                        self.c_trigger_event(BUY_ORDER_COMPLETED_EVENT,
                                                BuyOrderCompletedEvent(self._current_timestamp,
                                                                    tracked_order.client_order_id,
                                                                    tracked_order.base_asset,
                                                                    tracked_order.quote_asset,
                                                                    (tracked_order.fee_asset
                                                                        or tracked_order.quote_asset),
                                                                    tracked_order.executed_amount_base,
                                                                    tracked_order.executed_amount_quote,
                                                                    tracked_order.fee_paid,
                                                                    tracked_order.order_type))
                    else:
                        self.logger().info(f"The market sell order {tracked_order.client_order_id} has completed "
                                            f"according to user stream.")
                        self.c_trigger_event(SELL_ORDER_COMPLETED_EVENT,
                                                SellOrderCompletedEvent(self._current_timestamp,
                                                                        tracked_order.client_order_id,
                                                                        tracked_order.base_asset,
                                                                        tracked_order.quote_asset,
                                                                        (tracked_order.fee_asset
                                                                        or tracked_order.quote_asset),
                                                                        tracked_order.executed_amount_base,
                                                                        tracked_order.executed_amount_quote,
                                                                        tracked_order.fee_paid,
                                                                        tracked_order.order_type))
                else:
                    # check if its a cancelled order
                    # if its a cancelled order, check in flight orders
                    # if present in in flight orders issue cancel and stop tracking order
                    if tracked_order.is_cancelled:
                        if tracked_order.client_order_id in self._in_flight_orders:
                            self.logger().info(f"Successfully cancelled order {tracked_order.client_order_id}.")
                    else:
                        self.logger().info(f"The market order {tracked_order.client_order_id} has failed according to "
                                            f"order status API.")

                self.c_stop_tracking_order(tracked_order.client_order_id)

    async def _set_balances(self, updates):
        try:
            tokens = set(self.token_configuration.get_tokens())
            if len(tokens) == 0:
                await self.token_configuration._configure()
                tokens = set(self.token_configuration.get_tokens())

            async with self._lock:
                completed_tokens = set()
                for data in updates:
                    padded_total_amount : str = data['totalAmount']
                    token_id : int = data['tokenId']
                    completed_tokens.add(token_id)
                    padded_amount_locked : string = data['amountLocked']

                    token_symbol : str = self._token_configuration.get_symbol(token_id) 
                    total_amount : Decimal = self._token_configuration.unpad(padded_total_amount, token_id)
                    amount_locked : Decimal = self._token_configuration.unpad(padded_amount_locked, token_id)

                    self._account_balances[token_symbol] = total_amount
                    self._account_available_balances[token_symbol] = total_amount - amount_locked

                # Tokens with 0 balance aren't returned, so set any missing tokens to 0 balance
                for token_id in tokens - completed_tokens:
                    token_symbol : str = self._token_configuration.get_symbol(token_id) 
                    self._account_balances[token_symbol] = Decimal(0)
                    self._account_available_balances[token_symbol] = Decimal(0)

        except Exception as e:
            self.logger().error(f"Could not set balance {repr(e)}")

    # ----------------------------------------
    # User stream updates

    async def _iter_user_event_queue(self) -> AsyncIterable[Dict[str, Any]]:
        while True:
            try:
                yield await self._user_stream_tracker.user_stream.get()
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().network(
                    "Unknown error. Retrying after 1 seconds.",
                    exc_info=True,
                    app_warning_msg="Could not fetch user events from Loopring. Check API key and network connection."
                )
                await asyncio.sleep(1.0)

    async def _user_stream_event_listener(self):
        async for event_message in self._iter_user_event_queue():
            try:
                event: Dict[str, Any] = json.loads(event_message)
                topic: str = event['topic']['topic']
                data : Dict[str, Any] = event['data']
                if topic == 'account':
                    self._set_balances([data])
                elif topic == 'order':
                    client_order_id : str = data['clientOrderId']
                    tracked_order : LoopringInFlightOrder = self._in_flight_orders.get(client_order_id)

                    if tracked_order is None:
                        self.logger().debug(f"Unrecognized order ID from user stream: {client_order_id}.")
                        self.logger().debug(f"Event: {event_message}")
                        continue
                    
                    # update the tracked order
                    self._update_inflight_order(tracked_order, data)
                elif topic == 'sub':
                    pass
                elif topic == 'unsub':
                    pass
                else:
                    self.logger().debug(f"Unrecognized user stream event topic: {topic}.")                    

            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().error("Unexpected error in user stream listener loop.", exc_info=True)
                await asyncio.sleep(5.0)

    # ----------------------------------------
    # Polling Updates

    async def _polling_update(self):
        while True:
            try:
                self._poll_notifier = asyncio.Event()
                await self._poll_notifier.wait()

                await asyncio.gather(
                    self._update_balances(),
                    self._update_trading_rules(),
                    self._update_order_status(),
                )
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.logger().warning("Failed to fetch updates on Loopring. Check network connection.")
                self.logger().info(e)

    async def _update_balances(self):
        balances_response = await self.api_request("GET", BALANCES_INFO_ROUTE,
                                                    params = {
                                                        "accountId": self._loopring_accountid
                                                    })
        await self._set_balances(balances_response["data"])
    
    async def _update_trading_rules(self):
        markets_info, tokens_info = await asyncio.gather(
            self.api_request("GET", MARKETS_INFO_ROUTE),
            self.api_request("GET", TOKENS_INFO_ROUTE)
        )

        # Loopring fees not available from api

        markets_info = markets_info["data"]
        tokens_info = tokens_info["data"]
        tokens_info = {t['tokenId']:t for t in tokens_info}

        for market in markets_info:
            if market['enabled'] == True:
                baseid, quoteid = market['baseTokenId'], market['quoteTokenId']
                
                try:
                    self._trading_rules[market["market"]] = TradingRule(
                        trading_pair=market["market"],
                        min_order_size = self.token_configuration.unpad(tokens_info[baseid]['minOrderAmount'], baseid),
                        max_order_size = self.token_configuration.unpad(tokens_info[baseid]['maxOrderAmount'], baseid),
                        min_price_increment=Decimal(f"1e-{market['precisionForPrice']}"),
                        min_base_amount_increment=Decimal(f"1e-{tokens_info[baseid]['precision']}"),
                        min_quote_amount_increment=Decimal(f"1e-{tokens_info[quoteid]['precision']}"),
                        min_notional_size = self.token_configuration.unpad(tokens_info[quoteid]['minOrderAmount'], quoteid),
                        supports_limit_orders = True,
                        supports_market_orders = False
                    )
                except Exception as e:
                    self.logger().debug("Error updating trading rules")
                    self.logger().debug(str(e))
                    
    async def _update_order_status(self):
        tracked_orders = self._in_flight_orders.copy()

        for client_order_id, tracked_order in tracked_orders.iteritems():
            loopring_order_id = tracked_order.exchange_order_id

            try:
                loopring_order_request = await self.api_request("GET",
                                                                GET_ORDER_ROUTE,
                                                                params={
                                                                    "accountId": self._loopring_accountid,
                                                                    "orderHash": tracked_order.exchange_order_id
                                                                })
                data = loopring_order_request["data"]
            except Exception:
                self.logger().warning(f"Failed to fetch tracked Loopring order {tracked_order.exchange_order_id} from api")
                continue

            try:
                self._update_inflight_order(tracked_order, data)
            except Exception as e:
                self.logger().warning(f"Failed to update Loopring order {tracked_order.exchange_order_id}")
                self.logger().error(e)


    # ==========================================================
    # Miscellaneous
    # ----------------------------------------------------------

    cdef object c_get_order_price_quantum(self, str trading_pair, object price):
        return self._trading_rules[trading_pair].min_price_increment

    cdef object c_get_order_size_quantum(self, str trading_pair, object order_size):
        return self._trading_rules[trading_pair].min_base_amount_increment

    cdef object c_quantize_order_price(self, str trading_pair, object price):
        return price.quantize(self.c_get_order_price_quantum(trading_pair, price), rounding=ROUND_DOWN)

    cdef object c_quantize_order_amount(self, str trading_pair, object amount, object price = 0.0):
        quantized_amount = amount.quantize(self.c_get_order_size_quantum(trading_pair, amount), rounding=ROUND_DOWN)
        rules = self._trading_rules[trading_pair]

        if quantized_amount < rules.min_order_size:
            return s_decimal_0

        if price > 0 and price * quantized_amount < rules.min_notional_size:
            return s_decimal_0

        return quantized_amount

    cdef c_tick(self, double timestamp):
        cdef:
            int64_t last_tick = <int64_t> (self._last_timestamp / self._poll_interval)
            int64_t current_tick = <int64_t> (timestamp / self._poll_interval)

        self._tx_tracker.c_tick(timestamp)
        MarketBase.c_tick(self, timestamp)
        if current_tick > last_tick:
            if not self._poll_notifier.is_set():
                self._poll_notifier.set()
        self._last_timestamp = timestamp

    def _encode_request(self, url, method, params):
        url = urllib.parse.quote(url, safe='')
        data = urllib.parse.quote("&".join([f"{k}={str(v)}" for k, v in params.items()]), safe='')
        return "&".join([method, url, data])

    async def api_request(
        self, 
        http_method: str, 
        url: str, 
        data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = {},
        secure: bool = False) -> Dict[str, Any]:

        if self._shared_client is None:
            self._shared_client = aiohttp.ClientSession()

        if data is not None and http_method == "POST":
            data = json.dumps(data).encode('utf8')
            headers = {"Content-Type": "application/json"}

        headers.update(self._loopring_auth.generate_auth_dict())
        full_url = f"{self.API_REST_ENDPOINT}{url}"

        # Signs requests for secure requests
        if secure:
            ordered_data = self._encode_request(full_url, http_method, params)
            hasher = hashlib.sha256()
            hasher.update(ordered_data.encode('utf-8'))
            msgHash = int(hasher.hexdigest(), 16) % SNARK_SCALAR_FIELD
            signed = PoseidonEdDSA.sign(msgHash, FQ(int(self._loopring_private_key)))
            signature = ','.join(str(_) for _ in [signed.sig.R.x, signed.sig.R.y, signed.sig.s])
            headers.update({"X-API-SIG": signature})

        async with self._shared_client.request(http_method, url=full_url,
                                            timeout=API_CALL_TIMEOUT,
                                            data=data, params=params, headers=headers) as response:
            if response.status != 200:
                self.logger().info(f"Issue with Loopring API {http_method} to {url}, response: ")
                self.logger().info(await response.text)
                raise IOError(f"Error fetching data from {full_url}. HTTP status is {response.status}.")
            data = await response.json()
            return data
