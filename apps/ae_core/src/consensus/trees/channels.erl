-module(channels).
-export([new/8,serialize/1,deserialize/1,update/10,
	 write/2,get/2,delete/2,root_hash/1,
	 acc1/1,acc2/1,id/1,bal1/1,bal2/1,
	 last_modified/1, entropy/1,
	 nonce/1,delay/1, amount/1, slasher/1,
	 closed/1, verify_proof/4,
         dict_update/10, dict_delete/2, dict_write/2, dict_get/2,
	 test/0]).
%This is the part of the channel that is written onto the hard drive.

-record(channel, {id = 0, %the unique id number that identifies this channel
		  acc1 = 0, 
		  acc2 = 0, 
		  bal1 = 0, 
		  bal2 = 0, 
		  amount = 0, %this is how we remember the outcome of the last contract we tested, that way we can undo it.
		  nonce = 1,%How many times has this channel-state been updated. If your partner has a state that was updated more times, then they can use it to replace your final state.
		  timeout_height = 0,%when one partner disappears, the other partner needs to wait so many blocks until they can access their money. This records the time they started waiting. 
		  last_modified = 0,%this is used so that the owners of the channel can pay a fee for how long the channel has been open.
% we can set timeout_height to 0 to signify that we aren't in timeout mode. So we don't need the timeout flag.
		  %mode = 0,%0 means an active channel where money can be spent. 1 means that the channel is being closed by acc1. 2 means that the channel is being closed by acc2.
		  entropy = 0, %This is a nonce so that old channel contracts can't be reused, even if you make a new channel with the same partner you previously had a channel with.
		  delay = 0,%this is how long you have to wait since "last_modified" to do a channel_timeout_tx.
		  %we need to store this between a solo_close_tx and a channel_timeout_tx. That way we know we waited for long enough.
		  slasher = 0, %this is how we remember who was the last user to do a slash on a channel. If he is the last person to slash, then he gets a reward.
		  closed = false %when a channel is closed, set this to 1. The channel can no longer be modified, but the VM has access to the state it was closed on. So you can use a different channel to trustlessly pay whoever slashed.
		  %shares = 0 %This is a pointer to the root of a tree that holds all the shares.
		  }%
       ).
acc1(C) -> C#channel.acc1.
acc2(C) -> C#channel.acc2.
id(C) -> C#channel.id.
bal1(C) -> C#channel.bal1.
bal2(C) -> C#channel.bal2.
amount(C) -> C#channel.amount.
last_modified(C) -> C#channel.last_modified.
%mode(C) -> C#channel.mode.
entropy(C) -> C#channel.entropy.
nonce(C) -> C#channel.nonce.
delay(C) -> C#channel.delay.
slasher(C) -> C#channel.slasher.
closed(C) -> C#channel.closed.
%shares(C) -> C#channel.shares.

dict_update(Slasher, ID, Dict, Nonce, Inc1, Inc2, Amount, Delay, Height, Close) ->
    true = (Close == true) or (Close == false),
    true = Inc1 + Inc2 >= 0,
    Channel = dict_get(ID, Dict),
    CNonce = Channel#channel.nonce,
    NewNonce = if
		   Nonce == none -> CNonce;
		   true -> 
		       Nonce
	       end,
    T1 = Channel#channel.last_modified,
    DH = Height - T1,
    Bal1a = Channel#channel.bal1 + Inc1,% - RH,
    Bal2a = Channel#channel.bal2 + Inc2,% - RH,
    Bal1b = max(Bal1a, 0),
    Bal2b = max(Bal2a, 0),
    Bal1c = min(Bal1b, Bal1a+Bal2a),
    Bal2c = min(Bal2b, Bal1a+Bal2a),
    C = Channel#channel{bal1 = Bal1c,
                        bal2 = Bal2c,
                        amount = Amount,
                        nonce = NewNonce,
                        last_modified = Height,
                        delay = Delay,
                        slasher = Slasher,
                        closed = Close
		       },
    C.
    
update(Slasher, ID, Trees, Nonce, Inc1, Inc2, Amount, Delay, Height, Close) ->
    Channels = trees:channels(Trees),
    true = (Close == true) or (Close == false),
    true = Inc1 + Inc2 >= 0,
    {_, Channel, _} = get(ID, Channels),
    CNonce = Channel#channel.nonce,
    NewNonce = if
		   Nonce == none -> CNonce;
		   true -> 
		       %true = Nonce > CNonce,
		       Nonce
	       end,
    %true = Nonce > Channel#channel.nonce,
    T1 = Channel#channel.last_modified,
    DH = Height - T1,
    Governance = trees:governance(Trees),
    %CR = governance:get_value(channel_rent, Governance),
    %Rent = CR * DH,
    %RH = Rent div 2,%everyone needs to pay the network for the cost of having a channel open.
    %CR = S * Channel#channel.rent,
    Bal1a = Channel#channel.bal1 + Inc1,% - RH,
    Bal2a = Channel#channel.bal2 + Inc2,% - RH,
    Bal1b = max(Bal1a, 0),
    Bal2b = max(Bal2a, 0),
    Bal1c = min(Bal1b, Bal1a+Bal2a),
    Bal2c = min(Bal2b, Bal1a+Bal2a),
    %true = Bal1 >= 0,
    %true = Bal2 >= 0,
    %SR = shares:write_many(Shares, 0),
    C = Channel#channel{bal1 = Bal1c,
                        bal2 = Bal2c,
                        amount = Amount,
                        nonce = NewNonce,
                        last_modified = Height,
                        delay = Delay,
                        slasher = Slasher,
                        closed = Close
                        %shares = SR
		       },
    C.
    
new(ID, Acc1, Acc2, Bal1, Bal2, Height, Entropy, Delay) ->
    #channel{id = ID, acc1 = Acc1, acc2 = Acc2, 
	     bal1 = Bal1, bal2 = Bal2, 
	     last_modified = Height, entropy = Entropy,
	     delay = Delay}.
serialize(C) ->
    %ACC = constants:address_bits(),
    BAL = constants:balance_bits(),
    HEI = constants:height_bits(),
    NON = constants:channel_nonce_bits(),
    KL = id_size(),
    ENT = constants:channel_entropy(),
    CID = C#channel.id,
    Entropy = C#channel.entropy,
    Delay = constants:channel_delay_bits(),
    true = (Entropy - 1) < math:pow(2, ENT),
    true = (CID - 1) < math:pow(2, KL),
    Amount = C#channel.amount,
    HB = constants:half_bal(),
    true = Amount < HB,
    CR = case (C#channel.closed) of
	     true -> 1;
	     false -> 0
	 end,
    HS = constants:hash_size(),
    %Shares = shares:root_hash(C#channel.shares),
    %HS = size(Shares),
    true = size(C#channel.acc1) == constants:pubkey_size(),
    true = size(C#channel.acc2) == constants:pubkey_size(),
    << CID:(HS*8),
       (C#channel.bal1):BAL,
       (C#channel.bal2):BAL,
       (Amount+HB):BAL,
       (C#channel.nonce):NON,
       (C#channel.timeout_height):HEI,
       (C#channel.last_modified):HEI,
       Entropy:ENT,
       (C#channel.delay):Delay,
       CR:8,
       (C#channel.acc1)/binary,
       (C#channel.acc2)/binary
    >>.
deserialize(B) ->
    PS = constants:pubkey_size()*8,
    ACC = constants:address_bits(),
    BAL = constants:balance_bits(),
    HEI = constants:height_bits(),
    NON = constants:channel_nonce_bits(),
    KL = constants:key_length(),
    ENT = constants:channel_entropy(),
    Delay = constants:channel_delay_bits(),
    HS = constants:hash_size()*8,
    << ID:HS,
       B3:BAL,
       B4:BAL,
       B8:BAL,
       B5:NON,
       B6:HEI,
       B7:HEI,
       B11:ENT,
       B12:Delay,
       Closed:8,
       B1:PS,
       B2:PS
       %_:HS
    >> = B,
    CR = case Closed of
	     0 -> false;
	     1 -> true
	 end,
    #channel{id = ID, acc1 = <<B1:PS>>, acc2 = <<B2:PS>>, 
	     bal1 = B3, bal2 = B4, amount = B8-constants:half_bal(),
	     nonce = B5, timeout_height = B6, 
	     last_modified = B7,
	     entropy = B11, delay = B12,
	     closed = CR}.
dict_write(Channel, Dict) ->
    ID = Channel#channel.id,
    dict:store({channels, ID},
               serialize(Channel),
               Dict).
write(Channel, Root) ->
    ID = Channel#channel.id,
    M = serialize(Channel),
    %Shares = Channel#channel.shares,
    trie:put(ID, M, 0, Root, channels). %returns a pointer to the new root
id_size() -> constants:key_length().
get(ID, Channels) ->
    true = (ID - 1) < math:pow(2, id_size()),
    {RH, Leaf, Proof} = trie:get(ID, Channels, channels),
    V = case Leaf of
	    empty -> empty;
	    L -> deserialize(leaf:value(L))
	end,
    {RH, V, Proof}.
dict_get(Key, Dict) ->
    X = dict:fetch({channels, Key}, Dict),
    case X of
        0 -> empty;
        _ -> deserialize(X)
    end.
dict_delete(Key, Dict) ->      
    dict:store({channels, Key}, 0, Dict).
delete(ID,Channels) ->
    trie:delete(ID, Channels, channels).
root_hash(Channels) ->
    trie:root_hash(channels, Channels).
cfg() ->
    HashSize = constants:hash_size(),
    PathSize = constants:hash_size()*8,
    ValueSize = constants:channel_size(),
    MetaSize = 0,
    cfg:new(PathSize, ValueSize, accounts, 0, HashSize).
    %tree_child(accounts, HS*8, constants:account_size(), KL*2 div 8),
    %tree_child(channels, HS*8, constants:channel_size(), KL div 8),
verify_proof(RootHash, Key, Value, Proof) ->
    CFG = cfg(),
    V = case Value of
	    0 -> empty;
	    X -> X
	end,
    verify:proof(RootHash, 
		 leaf:new(Key, V, 0, CFG), 
		 Proof, CFG).
    
test() ->
    ID = 1,
    Acc1 = constants:master_pub(),
    Acc2 = constants:master_pub(),
    Bal1 = 200,
    Bal2 = 300,
    Height = 1,
    Entropy = 500,
    Delay = 11,
    A = new(ID,Acc1,Acc2,Bal1,Bal2,Height,Entropy,Delay),
    A = deserialize(serialize(A)),
    C = A,
    NewLoc = write(C, 0),
    {Root, C, Proof} = get(ID, NewLoc),
    true = verify_proof(Root, ID, serialize(C), Proof),
    success.
    

