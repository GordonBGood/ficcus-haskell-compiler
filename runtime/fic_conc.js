
// fic_conc.js -- Ficcus T1a-2: the JavaScript kernels of the `Concurrent` module (overlay/Concurrent.elm), the differential reference of
// runtime/fic_conc.h (docs/attach/T1A-NOTES.md, rules R1 to R8). Emitted once by the JavaScript generator (Ficcus.Mono.Concurrent.concJs)
// after the kernels of elm/core's Scheduler and Platform, in a program that reaches a kernel of the overlay; each kernel definition of
// the overlay becomes `var $author$project$Concurrent$<name> = _FicConc_<name>;`.
// It uses elm/core 1.0.5's Scheduler.js as generated: a task's tag `$` (0 succeed, 2 binding), a binding's callback `b` and kill `c`, a
// process's root `f`; a router's self process `h` (Platform.js); a self message `{$: 0, a: msg}`. The checks below fail at load time if
// they ever change (F4). O9 also counts the dispatches of Platform.js (`_Platform_dispatchEffects`, one `fx` mail per manager).
// Rules as in C: the operations that complete at once are `andThen op (succeed ())` (no yield); a block is a binding whose callback the
// waker calls (the woken process is queued); only the owner may receive (O8); a handle is an object with a numeric `$` (Debug.toString
// prints <internals>) and a distinct `id` (== compares ids).

var _FicConc_ids = 0;
var _FicConc_cur = null;
var _FicConc_router = null;
var _FicConc_fxPending = 0; // O9: dispatches begun whose `fx` mail this manager's onEffects has not yet taken (the C twin reads the state)
var _FicConc_kept = [];     // O9: channels whose oldest message waits for that onEffects

(function() {
	var bad = function(what) { throw new Error('internal: Concurrent: the scheduler of elm/core changed (' + what + ')'); };
	if (_Scheduler_binding(0).$ !== 2 || _Scheduler_succeed(0).$ !== 0) bad('task tags');
	var bnd = _Scheduler_binding(0);
	if (bnd.b !== 0 || !('c' in bnd)) bad('binding fields b, c');
	if (!/\bproc\.f\b/.test(_Scheduler_step.toString())) bad('process root f');
	var self = (_Platform_sendToSelf.f || _Platform_sendToSelf).toString();
	if (!/\brouter\.h\b/.test(self) || !/\$:\s*0\s*,/.test(self)) bad('router process h, self message tag 0');
	if (!/\$:\s*'fx'/.test(_Platform_dispatchEffects.toString())) bad('dispatch fx mail');
	var dispatch = _Platform_dispatchEffects;
	_Platform_dispatchEffects = function(managers, cmdBag, subBag) {
		_FicConc_fxPending++;
		return dispatch(managers, cmdBag, subBag);
	};
	var step = _Scheduler_step;
	_Scheduler_step = function(proc) {
		var prev = _FicConc_cur;
		_FicConc_cur = proc;
		try { step(proc); } finally { _FicConc_cur = prev; }
	};
})();

function _FicConc_op(f)
{
	return A2(_Scheduler_andThen, function(_) { return f(); }, _Scheduler_succeed(_Utils_Tuple0));
}

var _FicConc_unit = function() { return _Scheduler_succeed(_Utils_Tuple0); };

function _FicConc_record(kind)
{
	return { $: 9, id: ++_FicConc_ids, kind: kind, proc: null, owner: null, queue: [], awaiters: [], exit: null, killed: null, state: 0, waiting: null };
}

function _FicConc_end(c, state, exit)
{
	c.state = state;
	c.exit = exit;
	c.queue = [];
	c.waiting = null;
	var ws = c.awaiters;
	c.awaiters = [];
	for (var i = 0; i < ws.length; i++)
	{
		if (ws[i].p.f !== null) ws[i].cb(_Scheduler_succeed(exit));   // a killed waiter stays dead
	}
	c.proc = null;
}

var _FicConc_spawnRaw = F2(function(killed, body)
{
	return _FicConc_op(function() {
		var c = _FicConc_record(0);
		c.killed = killed;
		var root = A2(_Scheduler_andThen, function(v) {
			if (c.state === 0) _FicConc_end(c, 1, v);
			return _FicConc_unit();
		}, A2(_Scheduler_andThen, body, _Scheduler_succeed(c)));
		c.proc = _Scheduler_rawSpawn(root);                // queued: the parent goes on (R2)
		c.owner = c.proc;
		return _Scheduler_succeed(c);
	});
});

function _FicConc_address(x) { return x; }
function _FicConc_self(x) { return x; }
function _FicConc_toAddress(x) { return x; }
function _FicConc_channelId(x) { return x.id; }
function _FicConc_chanRefId(x) { return x.id; }

var _FicConc_send = F2(function(c, msg)
{
	return _FicConc_op(function() {
		if (c.kind === 1)
		{
			if (_FicConc_router !== null)
			{
				c.queue.push(msg);
				_Scheduler_rawSend(_FicConc_router.h, { $: 0, a: c });
			}
			return _FicConc_unit();
		}
		if (c.state !== 0) return _FicConc_unit();
		c.queue.push(msg);
		var w = c.waiting;
		if (w !== null)
		{
			c.waiting = null;
			if (w.within) { clearTimeout(w.timer); w.cb(_Scheduler_succeed(w.just(c.queue.shift()))); }
			else w.cb(_Scheduler_succeed(c.queue.shift()));
		}
		return _FicConc_unit();
	});
});

function _FicConc_ownerCheck(c, what)
{
	if (c.kind !== 0 || c.owner !== _FicConc_cur)
	{
		throw new Error('Concurrent.' + what + ': the mailbox belongs to another process (only the body given to spawnWith may receive from it)');
	}
}

function _FicConc_receive(c)
{
	return _FicConc_op(function() {
		_FicConc_ownerCheck(c, 'receive');
		if (c.queue.length > 0) return _Scheduler_succeed(c.queue.shift());
		return _Scheduler_binding(function(cb) { c.waiting = { cb: cb, within: false }; });
	});
}

var _FicConc_receiveWithinRaw = F4(function(ms, c, just, nothing)
{
	return _FicConc_op(function() {
		_FicConc_ownerCheck(c, 'receiveWithin');
		if (c.queue.length > 0) return _Scheduler_succeed(just(c.queue.shift()));
		return _Scheduler_binding(function(cb) {
			var w = { cb: cb, within: true, just: just, timer: null };
			w.timer = setTimeout(function() {
				if (c.waiting === w) { c.waiting = null; cb(_Scheduler_succeed(nothing)); }
			}, ms);
			c.waiting = w;
			return function() { clearTimeout(w.timer); };
		});
	});
});

function _FicConc_await(c)
{
	return _FicConc_op(function() {
		if (c.state !== 0) return _Scheduler_succeed(c.exit);
		return _Scheduler_binding(function(cb) { c.awaiters.push({ p: _FicConc_cur, cb: cb }); });
	});
}

function _FicConc_kill(c)
{
	return _FicConc_op(function() {
		if (c.state !== 0) return _FicConc_unit();
		var own = c.proc === _FicConc_cur;
		if (!own)
		{
			var t = c.proc.f;                                  // E2's (Elm's) kill: the binding's kill function, the root dropped
			if (t && t.$ === 2 && t.c) t.c();
			c.proc.f = null;
		}
		_FicConc_end(c, 2, c.killed);
		if (own) return _Scheduler_binding(function(cb) {}); // a self kill: the process stops after the operation
		return _FicConc_unit();
	});
}

function _FicConc_newChannel(u)
{
	return _FicConc_op(function() { return _Scheduler_succeed(_FicConc_record(1)); });
}

function _FicConc_current(c)
{
	return _FicConc_op(function() { return _Scheduler_succeed(c.queue[0]); });
}

// listeners 0 (onSelfMsg): kept while a dispatch is under way (O9); -1 (onEffects, still no listen): dropped
var _FicConc_advance = F2(function(c, listeners)
{
	return _FicConc_op(function() {
		if (listeners === 0 && _FicConc_fxPending > 0) { _FicConc_kept.push(c); return _FicConc_unit(); }
		c.queue.shift();
		return _FicConc_unit();
	});
});

// the kept channels, oldest first; forgotten here
function _FicConc_held(u)
{
	return _FicConc_op(function() {
		var l = _List_Nil;
		for (var i = _FicConc_kept.length - 1; i >= 0; i--) l = _List_Cons(_FicConc_kept[i], l);
		_FicConc_kept = [];
		return _Scheduler_succeed(l);
	});
}

// the start of every onEffects of the manager: one dispatch taken
function _FicConc_attach(router)
{
	return _FicConc_op(function() {
		if (_FicConc_router === null) _FicConc_router = router;
		if (_FicConc_fxPending > 0) _FicConc_fxPending--;
		return _FicConc_unit();
	});
}
