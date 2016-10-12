(**
 * Copyright 2016, Aesthetic Integration Limited. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *    * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *    * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *
 *    * Neither the name of Aesthetic Integration Limited nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *)


(* An example proving a pricing fairness condition                *)

type order_type = Market | Limit | Quote;;
type order_attr = Normal | IOC | FOK;;

(*
   Each client should be assigned to a category/group.
   They can also specify which groups they would like to trade against.

   G_MM = Market Makers, G_DMA = Direct Market Access, G_INT = Internal
*)

type group = G_MM | G_DMA | G_INT;;

type client = { client_id : int;
                client_group : group;
                client_will_trade_against : group list };;

type order = { order_id : int;
               order_type : order_type;
               order_qty : int;
               hidden_liquidity : bool;
               max_visible_qty : int;
               display_qty : int;
               replenish_qty : int;
               order_price : float;
               order_time : int;
               order_src : client;
               order_attr : order_attr };;

let order_higher_ranked_long (o1, o2) =
  if o1.order_type = o2.order_type then
    (o1.order_price >= o2.order_price ||
       (o1.order_price = o2.order_price &&
          o1.order_time <= o2.order_time))
  else (o1.order_type = Market && o2.order_type = Limit);;

let order_higher_ranked_short (o1, o2) =
  if o1.order_type = o2.order_type then
    (o1.order_price <= o2.order_price ||
       (o1.order_price = o2.order_price &&
          o1.order_time <= o2.order_time))
  else (o1.order_type = Market && o2.order_type = Limit);;

type fill_price =
  | Known of float
  | Unknown
  | T_O_P of float;;

type order_book = { buys : order list;
                    sells : order list };;

let older_price (o1, o2) =
  if o1.order_time > o2.order_time
  then o2.order_price else o1.order_price;;

let empty_book = { buys = []; sells = [] };;

let empty_fill_stack = [];;

type o_fill = { order_long : order;
                order_short : order;
                fill_qty : int;
                fill_price : fill_price;
                fill_time : int };;

type fill_stack = o_fill list;;

:load Messaging.ml

(* State *)

type exchange_period =
  | EP_PRE_OPEN
  | EP_OPEN_UNCROSS
  | EP_OPEN
  | EP_MAIN_TRADING
  | EP_CLOSING
  | EP_CLOSE_UNCROSS;;

type book_state = BS_NON_OPENING
                | BS_DELAY_OPEN
                | BS_OPENABLE
                | BS_AVALANCHE
                | BS_NO_UNDERLIER
                | BS_STOP_TRADE
                | BS_NORMAL;;

type mode = CONT_TRADE | AUCTION;;

type exchange_state =
    { period : exchange_period;
      book_state : book_state;
      mode : mode;
      cur_time : int;
      stop_trading_button_pressed : bool;
      match_price_out_of_bounds : bool;
      ref_price : float;
      ref_price_bound : float;
      order_book : order_book;
      fill_stack : fill_stack;
      shadow_order_book : order_book;
      shadow_msgs : msg_buffer;
      in_fill_stack_mode : bool;
      fill_log : o_fill list;
      unprocessed_msgs : msg_buffer;
      processed_msgs : msg_buffer;
      top : float option;
    };;

let states_same_except_order_book (s, s') =
  s.period = s'.period
  && s.period = EP_MAIN_TRADING
  && s.book_state = s'.book_state
  && s.book_state = BS_NORMAL
  && s.mode = s'.mode
  && s.mode = CONT_TRADE
  && s.cur_time = s'.cur_time
  && s.stop_trading_button_pressed = s'.stop_trading_button_pressed
  && s.match_price_out_of_bounds = s'.match_price_out_of_bounds
  && s.ref_price = s'.ref_price
  && s.ref_price_bound = s'.ref_price_bound
  && s.fill_stack = s'.fill_stack
  && s.shadow_order_book = s'.shadow_order_book
  && s.shadow_order_book = empty_book
  && s.shadow_msgs = s'.shadow_msgs
  && s.in_fill_stack_mode = s'.in_fill_stack_mode
  && s.in_fill_stack_mode = false
  && s.fill_log = s'.fill_log
  && s.unprocessed_msgs = s'.unprocessed_msgs
  && s.processed_msgs = s'.processed_msgs
  && s.top = s'.top;;

(* Need range-type thms *)

let best_buy (s : exchange_state) =
  if s.order_book.buys <> [] then
    Some (List.hd (s.order_book.buys))
  else None;;

let best_sell (s : exchange_state) =
  if s.order_book.sells <> [] then
    Some (List.hd (s.order_book.sells))
  else None;;

let is_a_match (s : exchange_state) =
  (s.period = EP_MAIN_TRADING && s.book_state = BS_NORMAL)
  &&
    match best_buy s, best_sell s with
      Some bb, Some bs ->
      bb.order_price >= bs.order_price
      || bb.order_type = Market || bs.order_type = Market
    | _ -> false;;

let match_qty (s : exchange_state) =
  match best_buy s, best_sell s with
    Some bb, Some bs -> min (bb.display_qty, bs.display_qty)
  | _ -> 0;;

let price_round (price, step) = price;;

let active_book (s : exchange_state) =
  if s.in_fill_stack_mode then
    s.shadow_order_book else
    s.order_book;;

let next_buy (s : exchange_state) =
  let book = s.order_book in
  let buys = book.buys in
  match buys with
    [] -> None
  | [o1] -> None
  | o1 :: o2 :: _ ->
     Some o2;;

let next_sell (s : exchange_state) =
  let book = s.order_book in
  let sells = book.sells in
  match sells with
    [] -> None
  | [o1] -> None
  | o1 :: o2 :: _ ->
     Some o2;;

type fill_action =
  | Accept
  | AcceptAndCancel
  | RejectAndCancel
  | AcceptAndCreateNew of order;;

let match_price (s : exchange_state) =
  let bb = best_buy s in
  let bs = best_sell s in
  match bb, bs with
    Some bb, Some bs ->
    begin
      match bb.order_type, bs.order_type with
      | (Limit, Limit) ->
         Known (older_price (bb, bs))

      | (Quote, Quote) ->
         Known (older_price (bb, bs))

      | (Market, Market) ->
         if bb.order_qty <> bs.order_qty then Unknown
         else
           (* need to look at other orders in the order book *)
           let bestBuy = next_buy s in
           let bBid =
             match bestBuy with
               Some bestBuy ->
               if bestBuy.order_type = Market then None
               else Some bestBuy.order_price
             | _ -> None in

           let bestSell = next_sell s in
           let bAsk =
             match bestSell with
               Some bestSell ->
               if bestSell.order_type = Market then None
               else Some bestSell.order_price
             | _ -> None in
           begin
             match bBid, bAsk with
             | (None, None) -> Known s.ref_price
             | (None, Some ask) ->
                if ask < s.ref_price then Known ask
                else Known s.ref_price
             | (Some bid, None) ->
                if bid > s.ref_price then Known bid
                else Known s.ref_price
             | (Some bid, Some ask) ->
                if bid > s.ref_price then Known bid
                else
                  if ask < s.ref_price then Known ask
                  else Known s.ref_price
           end

      | (Market, Limit)   -> Known bs.order_price

      | (Limit, Market)   -> Known bb.order_price

      | (Quote,  Limit)   ->
         if bb.order_time > bs.order_time then
           (* incoming quote *)
           begin
             let nextSellLimit = next_sell s in
             if bb.order_qty < bs.order_qty then Known bs.order_price
             else if bb.order_qty = bs.order_qty then
               match nextSellLimit with
               | None      -> Known bb.order_price
               | Some ord  -> Known ord.order_price
             else Unknown
           end
         else
           (* existing quote's price is used *)
           Known bb.order_price

      | (Quote, Market) ->
         if bb.order_time > bs.order_time then
           (* incoming quote *)
           begin
             let nextSellLimit = next_sell s in
             if bb.order_qty < bs.order_qty then Known bs.order_price
             else if bb.order_qty = bs.order_qty then
               match nextSellLimit with
               | None      -> Known bb.order_price
               | Some ord  -> Known ord.order_price
             else Unknown
           end
         else
           (* existing quote's price is used *)
           Known bb.order_price

      | (Limit, Quote) ->
         if bb.order_time > bs.order_time then
           begin
             (* incoming quote *)
             let nextBuyLimit = next_buy s in
             if bs.order_qty < bb.order_qty then Known bb.order_price
             else if bb.order_qty = bs.order_qty then
               (match nextBuyLimit with
                | None      -> Known bs.order_price
                | Some ord  -> Known ord.order_price
               )
             else Unknown
           end
         else
           (* existing quote's price is used *)
           Known bs.order_price

      | (Market, Quote)   ->
         if bb.order_time > bs.order_time then
           begin
             (* incoming quote *)
             let nextBuyLimit = next_buy s in
             if bs.order_qty < bb.order_qty then Known bb.order_price
             else if bb.order_qty = bs.order_qty then
               (match nextBuyLimit with
                | None      -> Known bs.order_price
                | Some ord  -> Known ord.order_price
               )
             else Unknown
           end
         else
           (* existing quote's price is used *)
           Known bs.order_price
    end

  | _ -> Unknown;;

(* ::::::::::::::::::::::::::::::::::::::::::::: *)
(* Pricing fairness - Information Flow Analysis  *)
(* ::::::::::::::::::::::::::::::::::::::::::::: *)

let orders_same_except_src (o1, o2) =
  (o1.order_qty = o2.order_qty
   && o1.order_price = o2.order_price
   && o1.order_time = o2.order_time
   && o1.order_type = o2.order_type
   && o1.order_attr = o2.order_attr);;

(* Let's refine it into something that's true *)

verify match_price_ignores_order_src (s, s', b1, s1, b2, s2) =
  (orders_same_except_src (b1, b2)
   && orders_same_except_src (s1, s2)
   && states_same_except_order_book (s, s')
   && List.tl s.order_book.buys = List.tl s'.order_book.buys
   && List.tl s.order_book.sells = List.tl s'.order_book.sells
   && best_buy s = Some b1
   && best_sell s = Some s1
   && best_buy s' = Some b1
   && best_sell s' = Some s2)
    ==>
  (match_price s = match_price s');;
