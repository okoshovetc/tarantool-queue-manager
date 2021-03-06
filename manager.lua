local log   = require 'log'
local queue = require 'queue'
local fiber = require 'fiber'
local json  = require 'json'

local fiber_log = {}

function fiber_log.info (str, ...)
	log.info(
		table.concat({"[FIBER::%s::%d] ", str}),
		(fiber.self().name()  or ''), (fiber.self().id() or -1), ...
	)
end

function fiber_log.error (str, ...)
	log.error(
		table.concat({"[FIBER::%s::%d] ", str}),
		(fiber.self().name()  or ''), (fiber.self().id() or -1), ...
	)
end

local base58 = { "A","B","C","D","E","F","G","H","J","K","L","M","N","P","Q","R","S","T","U","V","W","X","Y","Z","a","b","c","d","e","f","g","h","i","j","k","m","n","o","p","q","r","s","t","u","v","w","x","y","z","1","2","3","4","5","6","7","8","9" }
math.randomseed(tonumber(fiber.time64()))

local randomb58 = function (len)
	if not len or len == 0 then
		return ''
	end

	local rand = ''
	for i = 1,len do
		rand = rand .. base58[ math.random(1,#base58) ]
	end
	return rand
end

local M = {}

local defaults = {
	default_delay = 1,
	delay_multiplier = 2,
	delay_threshold = 3600,
	max_attempts = -1,
	prefix_generator = function ()
		return randomb58(10)
	end,

	on_take = function(self, task)
		fiber_log.info("[%s] task=%s is taken", task.prefix, task)
	end,

	on_put = function(self, task)
		fiber_log.info("[%s] task=%s is put to queue", task.prefix, task)
	end,

	on_success = function(self, task, result, ...)
		fiber_log.info(
			"[%s] task=%s is finished successfully with result=%s",
			task.prefix, task, string.format(result or '', ...)
		)
	end,

	on_fail = function(self, task, error, ...)
		fiber_log.error(
			"[%s] task=%s has failed with error=%s, delay=%d",
			task.prefix, task, string.format(error or '', ...), (task.delay or 0)
		)
	end,

	on_fatal = function(self, task, error, ...)
		fiber_log.error(
			"[%s] task=%s has a fatal failure=%s, burrying",
			task.prefix, task, string.format(error or '', ...)
		)
	end,

	on_delay = function (self, task)
		task.delay = task.delay or self.default_delay
		task.delay = task.delay * self.delay_multiplier
		if task.delay > self.delay_threshold then
			task.delay = self.delay_threshold
		end
		return task
	end,

	on_attempts = function (self, task)
		task.attempts = task.attempts or 0
		task.attempts = task.attempts + 1
		return task
	end,

	__tostring = function (task)
		return json.encode(task.data)
	end,

	validate_task = function(task_data)
		return true
	end
}

local put = function (qm, task_data, delay)
	local ok, err = qm.validate_task(task_data)
	if not ok then
		return nil, err
	end

	local task = setmetatable({
		prefix = qm.prefix_generator(),
		data = task_data,
		delay = delay
	}, {
		__tostring = qm.__tostring
	})

	qm:on_put(task, { delay = delay or 0 })
	return queue.tube[qm.qname]:put(task)
end

local take = function (qm, timeout)
	local t = queue.tube[qm.qname]:take(timeout)
	if not t then
		return nil
	end

	local task = setmetatable({
		id = t[1],
		delay = t[3].delay,
		attempts = t[3].attempts or 0,
		prefix = t[3].prefix,
		data = t[3].data,
		qmanager = qm,
		log_info = function (task, str, ...)
			fiber_log.info(
				table.concat({"[%s] ", str}),
				task.prefix, ...
			)
		end,

		log_error = function (task, str, ...)
			fiber_log.error(
				table.concat({"[%s] ", str}),
				task.prefix, ...
			)
		end,

		success = function (task, result, ...)
			task.qmanager:on_success(task, result, ...)
			return queue.tube[task.qmanager.qname]:ack(task.id)
		end,

		fail = function (task, error, ...)
			task.qmanager:on_delay(task)
			task.qmanager:on_attempts(task)
			task.qmanager:on_fail(task, error, ...)

			if task.qmanager.max_attempts > 0 and task.attempts > task.qmanager.max_attempts then
				return task:fatal("task reached max attempts")
			end

			local upt = box.space[task.qmanager.qname]:update(task.id, {{'=', 8, {
				data     = task.data,
				prefix   = task.prefix,
				delay    = task.delay,
				attempts = task.attempts
			}}})
			return queue.tube[task.qmanager.qname]:release(task.id, { delay = task.delay })
		end,

		fatal = function (task, error, ...)
			task.qmanager:on_fatal(task, error, ...)
			return queue.tube[task.qmanager.qname]:bury(task.id)
		end,
	}, {
		__tostring = qm.__tostring
	})

	qm:on_take(task)
	return task
end

function M.attach_on_queue (qname, args)
	local manager = {}
	manager.qname = qname
	assert(qname, "no queue name given")
	assert(queue.tube[qname], "found no queue=" .. qname)
	assert(type(args) == 'table', "not a table given")

	for k, v in pairs(defaults) do
		if args[k] ~= nil then
			manager[k] = args[k]
		else
			manager[k] = defaults[k]
		end
	end

	for _, v in ipairs({
		'on_take', 'on_put', 'on_success',
		'on_fail', 'on_fatal', 'on_delay',
		'prefix_generator', '__tostring', 'validate_task'
	}) do
		assert(type(manager[v]) == 'function', "not a function for " .. v)
	end

	manager.take = function (timeout) return take(manager, timeout) end
	manager.put = function (task_data, delay) return put(manager, task_data, delay) end

	return manager
end

return M
