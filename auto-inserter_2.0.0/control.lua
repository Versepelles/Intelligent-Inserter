require("config")

function pall(msg)
	if not verbose then return end
	for __, player in pairs(game.players) do
		if player.connected then
			player.print(msg)
		end
	end
end

-- creates a small area around a point
function make_tiny_aabb(point)
    local d = 0.1 		-- a small deviation
    return {{point.x-d, point.y-d}, {point.x+d, point.y+d}}
end    

-- return the logistic chest at the given point, or nil if none exists
function get_logistic_chest_at(surface, point)
    local targets = surface.find_entities_filtered{
        type = "logistic-container",
        area = make_tiny_aabb(point)
    }
    if #targets == 1 then
        return targets[1]
    end
    return nil
end 

-- return the assembling machine at the given point, or nil if none exists
function get_assembly_at(surface, p)
    local targets = surface.find_entities_filtered{
        type = "assembling-machine",
        area = make_tiny_aabb(p)
    }
    if #targets == 1 then
        return targets[1]
    end
    return nil
end 

-- get the filter output count for an item based on stack size
function get_desired_output_count(name)
    return game.item_prototypes[name].stack_size
end

-- get the filter input count for an item based on stack size
function get_desired_input_count(recipe, name)
	local count = 0
	for __, ingredient in pairs(recipe.ingredients) do
		if ingredient.name == name then
			count = ingredient.amount * ingredient_request_multiplier
		end
	end
	return count
end

-- get item names from a recipe product list (discard fluids, etc)
function get_item_product_names(products)
    local item_names = {}
    for _,product in ipairs(products) do
        -- MAGIC NUMBER ... ITEM (see http://lua-api.factorio.com/latest/Concepts.html#Product)
        if product.type == 0 then
            table.insert(item_names, product.name)
        end
    end
    return item_names
end

-- set up an assembler to provider chest and limit the output inventory to one stack. returns a message
function setup_for_output(inserter, provider, assembly)
    if assembly.recipe == nil then
		return {"no-recipe"}
    end
	
    local product_names = get_item_product_names(assembly.recipe.products)
    if #product_names > 1 then
        return {"multiple-outputs"}
    end
    
    local product_name = product_names[1]
    inserter.set_filter(1, product_name)
    
	-- limit the output chest to one stack
	provider.get_inventory(defines.inventory.chest).setbar(1)
	--[[
    -- set the circuit condition on the inserter to operate only when there is less than one stack in the provider output
    inserter.set_circuit_condition(2,{
        condition = {
            first_signal= {
                type = "item",
                name = product_name
            },
            comparator =  "<",
            constant = get_desired_output_count(product_name)
        }
    })
	]]--
	return {"success"}
end

-- find a requester slot available to place item (name).
-- takes requester chest, a list of visited slot indices, and 
-- returns the slot index, simple item stack
function find_free_request_slot(requester, visited, name)
    for i = 1,8 do
        if not visited[i] then
            local item = requester.get_request_slot(i)
            if item == nil or item.name == name then
                return i, item
            end
        end
    end
    return nil, nil
end

-- configure the requester slots for the chest
function setup_for_input(inserter, requester, assembly)
    if assembly.recipe == nil then
		return {"no-recipe"}
    end
    
    local slots = {}
    local visited = {}
    
    for _,ingredient in ipairs(assembly.recipe.ingredients) do
        if ingredient.type == "item" then
            local slot, item  = find_free_request_slot(requester, visited, ingredient.name)
            if slot == nil then
                return {"no-free-requester-slot"}
            end
            visited[slot] = true
            table.insert(slots,{slot=slot,name=ingredient.name,item=item})
        end
    end
    
    local max_filter_count = 5
    local set_filter = #slots <= max_filter_count
    for i, slot in ipairs(slots) do
        local count = get_desired_input_count(assembly.recipe, slot.name)
        if slot.item and slot.item.count and slot.item.count > count then
            count = slot.item.count
        end
        requester.set_request_slot({name = slot.name, count = count}, slot.slot)
        if set_filter then
            inserter.set_filter(i, slot.name)
        end
    end
	return {"success"}
end

-- returns whether this is a logistic-chest-requester (modded items would need additional support)
function is_logistic_requester(entity)
    return (entity and entity.valid and entity.name == "logistic-chest-requester")
end

-- returns whether this is a logistic provider chest (modded items would need additional support)
function is_logistic_provider(entity)
    return (entity and entity.valid and (entity.name == "logistic-chest-active-provider" or entity.name == "logistic-chest-passive-provider"))
end

-- called when a filter-type inserter is placed. hooks it up if requester/provider chest available.
function place_auto_inserter(entity)
    local delta = {x=math.floor(0.5-entity.position.x+entity.drop_position.x),
                   y=math.floor(0.5-entity.position.y+entity.drop_position.y)}
    local fetch_position = {x=entity.position.x - delta.x,
                            y=entity.position.y - delta.y}
	local setup_message = {"explain-setup"}
	
    local drop_chest = get_logistic_chest_at(entity.surface, entity.drop_position)
	local fetch_chest = get_logistic_chest_at(entity.surface, fetch_position)
 
	-- check if we have a requester chest going into assembling machine
    if fetch_chest and is_logistic_requester(fetch_chest) then
		local assembly = get_assembly_at(entity.surface, entity.drop_position)
		if assembly then
			setup_message = setup_for_input(entity, fetch_chest, assembly)
		else
			setup_message = {"assembler-for-requester-missing"}
		end
	end
	
	-- check if we have assembling machine going into provider chest
    if drop_chest and is_logistic_provider(drop_chest) then
        local assembly = get_assembly_at(entity.surface, fetch_position)
        if assembly then
            setup_message = setup_for_output(entity, drop_chest, assembly)
			assembling_to_provider_success = true
        else
			setup_message = {"assembler-for-provider-missing"}
		end
	end
	
	-- display text based on outcome of the setup
	pall(setup_message)
end

script.on_event(defines.events.on_built_entity, function (event)
	local ent = event.created_entity
	if ent.name == "filter-inserter" then
		place_auto_inserter(ent)
	end	
end)

--game.on_event(defines.events.on_robot_built_entity, on_built_entity)

