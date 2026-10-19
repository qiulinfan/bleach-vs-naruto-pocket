-- Versioned save slots (options, keys, musou), so that updating the game never
-- loses or spoils a save:
-- - an older slot is read through the slot's migrations, one schema step at a time;
-- - a slot from a newer build (the player went back a version) is read for what this
--   build knows and never written over;
-- - fields this build does not know (a newer build added them) are kept when it saves;
-- - a damaged slot gives its previous version (the engine's .bak), which is written
--   back at once.
-- A schema number goes up only when a field changes meaning; adding a field does not
-- need one. The engine writes each slot atomically. Not attached to any actor.
local kept = {} -- slot -> {fields = the last read data, newer = from a newer build}

local function copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end

BVNSaveSlot = {
	-- The slot's data at this build's schema, or nil (none, or unreadable). migrations[v]
	-- turns schema v data into schema v + 1.
	Read = function(slot, schema, migrations)
		kept[slot] = nil
		if not Save then return nil end
		local r = Save.Read(slot, {fallback = true})
		if not (r and r.ok and type(r.data) == "table") then return nil end
		local v, data = r.schema_version, r.data
		while v < schema do
			local step = migrations and migrations[v]
			if not step then
				Debug.Log("BVN: no migration of save " .. slot .. " from schema " .. v)
				return nil
			end
			data = step(data) or data
			v = v + 1
		end
		kept[slot] = {fields = copy(data), newer = v > schema}
		if v > schema then
			Debug.Log("BVN: save " .. slot .. " is from a newer version (schema " .. v .. "); it is read, not written")
		elseif r.recovered then
			Debug.Log("BVN: save " .. slot .. " was damaged; its previous version was restored")
			BVNSaveSlot.Write(slot, schema, data)
		end
		return data
	end,

	-- Writes `data` over the fields read last (so unknown ones stay); false and nothing
	-- written when the slot holds a newer build's save.
	Write = function(slot, schema, data)
		if not Save then return false end
		local k = kept[slot]
		if k and k.newer then return false end
		local out = k and copy(k.fields) or {}
		for key, v in pairs(data) do out[key] = v end
		local r = Save.Write(slot, schema, out)
		if not r.ok then
			Debug.Log("BVN: cannot save " .. slot .. ": " .. tostring(r.code) .. " " .. tostring(r.error))
			return false
		end
		kept[slot] = {fields = out, newer = false}
		return true
	end,

	-- Whether the slot was written by a newer build (tests, the options screen).
	IsNewer = function(slot) return kept[slot] ~= nil and kept[slot].newer end,
}
