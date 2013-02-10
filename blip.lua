#!/usr/bin/env lem
--
-- This file is part of blipserver.
-- Copyright 2011 Emil Renner Berthing
--
-- blipserver is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version.
--
-- blipserver is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with blipserver.  If not, see <http://www.gnu.org/licenses/>.
--

local utils        = require 'lem.utils'
local queue        = require 'lem.queue'
local io           = require 'lem.io'
local postgres     = require 'lem.postgres'
local qpostgres    = require 'lem.postgres.queued'
local httpserv     = require 'lem.http.server'
local hathaway     = require 'lem.hathaway'

local assert = assert
local format = string.format
local tonumber = tonumber

local blip = queue.new()

utils.spawn(function()
	local serial = assert(io.open('/dev/serial/blipduino', 'r'))
	local db = assert(postgres.connect('user=powermeter dbname=powermeter'))
	local now = utils.now
	assert(db:prepare('put', 'INSERT INTO readings VALUES ($1, $2)'))

	-- discard first two readings
	assert(serial:read('*l'))
	assert(serial:read('*l'))

	while true do
		local ms = assert(serial:read('*l'))
		local stamp = format('%0.f', now() * 1000)

		print(stamp, ms, blip.n)
		blip:signal(stamp, ms)
		assert(db:run('put', stamp, ms))
	end
end)

local function sendfile(content, path)
	local file = assert(io.open(path))
	local size = assert(file:size())
	return function(req, res)
		res.headers['Content-Type'] = content
		res.headers['Content-Length'] = size
		res.file = file
	end
end

local index_html = sendfile('text/html; charset=UTF-8', 'index.html')

hathaway.import()

GET('/',               index_html)
GET('/index.html',     index_html)
GET('/jquery.js',      sendfile('text/javascript; charset=UTF-8', 'jquery.js'))
GET('/jquery.flot.js', sendfile('text/javascript; charset=UTF-8', 'jquery.flot.js'))
GET('/excanvas.js',    sendfile('text/javascript; charset=UTF-8', 'excanvas.js'))
GET('/ribbon.png',     sendfile('image/png',                      'ribbon.png'))
GET('/favicon.ico',    sendfile('image/x-icon',                   'favicon.ico'))

local function apiheaders(headers)
	headers['Content-Type'] = 'text/javascript; charset=UTF-8'
	headers['Cache-Control'] = 'max-age=0, must-revalidate'
	headers['Access-Control-Allow-Origin'] = '*'
	headers['Access-Control-Allow-Methods'] = 'GET'
	headers['Access-Control-Allow-Headers'] = 'origin, x-requested-with, accept'
	headers['Access-Control-Max-Age'] = '60'
end

local function apioptions(req, res)
	apiheaders(res.headers)
	res.status = 200
end

OPTIONS('/blip', apioptions)
GET('/blip', function(req, res)
	apiheaders(res.headers)

	local stamp, ms = blip:get()
	res:add('[%s,%s]', stamp, ms)
end)

local function add_json(res, values)
	res:add('[')

	local n = #values
	if n > 0 then
		for i = 1, n-1 do
			local point = values[i]
			res:add('[%s,%s],', point[1], point[2])
		end
		local point = values[n]
		res:add('[%s,%s]', point[1], point[2])
	end

	res:add(']')
end

local db = assert(qpostgres.connect('user=powermeter dbname=powermeter'))
assert(db:prepare('get',  'SELECT stamp, ms FROM readings WHERE stamp >= $1 ORDER BY stamp LIMIT 2000'))
assert(db:prepare('last', 'SELECT stamp, ms FROM readings ORDER BY stamp DESC LIMIT 1'))

OPTIONS('/last', apioptions)
GET('/last', function(req, res)
	apiheaders(res.headers)

	local point = assert(db:run('last'))[1]

	res:add('[%s,%s]', point[1], point[2])
end)

OPTIONSM('^/since/(%d+)$', apioptions)
GETM('^/since/(%d+)$', function(req, res, since)
	if #since > 15 then
		httpserv.bad_request(req, res)
		return
	end
	apiheaders(res.headers)
	add_json(res, assert(db:run('get', since)))
end)

OPTIONSM('^/last/(%d+)$', apioptions)
GETM('^/last/(%d+)$', function(req, res, ms)
	if #ms > 15 then
		httpserv.bad_request(req, res)
		return
	end
	apiheaders(res.headers)

	local since = format('%0.f',
		utils.now() * 1000 - tonumber(ms))

	add_json(res, assert(db:run('get', since)))
end)

hathaway.debug = print
assert(Hathaway('*', arg[1] or 8080))

-- vim: syntax=lua ts=2 sw=2 noet:
