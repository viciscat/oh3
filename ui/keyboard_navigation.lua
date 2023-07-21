local keyboard_navigation = {}
local current_screen
local selected_element

function keyboard_navigation.set_screen(screen)
    current_screen = screen
    selected_element = nil
end

-- gets the first selectable element and populates the indices table
local function get_first_element(element)
    if element.selectable then
        return element
    elseif element.elements then
        for i = 1, #element.elements do
            local first_elem = get_first_element(element.elements[i])
            if first_elem then
                return first_elem
            end
        end
    elseif element.element then
        local first_elem = get_first_element(element.element)
        if first_elem then
            return first_elem
        end
    end
end

function keyboard_navigation.select_element(element)
    if element ~= selected_element then
        if selected_element then
            selected_element.selected = false
            if selected_element.selection_handler then
                selected_element.selection_handler()
            end
        end
        selected_element = element
        if element then
            element.selected = true
            if element.selection_handler then
                element.selection_handler(element)
            end
        end
    end
end

function keyboard_navigation.deselect_element(element)
    if element == selected_element then
        keyboard_navigation.select_element()
    end
end

function keyboard_navigation.move(dx, dy)
    if dx ~= 0 and dy ~= 0 then
        error("keyboard navigation can only move in one direction at a time")
    elseif dx == 0 and dy == 0 then
        error("keyboard navigation move called without movement")
    elseif math.floor(dx) ~= dx or math.floor(dy) ~= dy then
        error("keyboard navigation can only move whole elements at a time")
    end
    local new_elem = selected_element
    if selected_element then
        local function move(elem, dir, num)
            local parent = elem.parent
            if parent then
                if parent.direction and parent.direction == dir then
                    local new_index = elem.parent_index + num
                    if parent.elements[new_index] then
                        return parent.elements[new_index]
                    end
                end
                local next_elem = move(parent, dir, num)
                if not next_elem then
                    return
                end
                return get_first_element(next_elem)
            else
                return
            end
        end
        local direction, move_num
        if dx ~= 0 then
            direction = "row"
            move_num = dx
        elseif dy ~= 0 then
            direction = "column"
            move_num = dy
        end
        local last_selectable_elem
        repeat
            if new_elem.selectable then
                last_selectable_elem = new_elem
            end
            new_elem = move(new_elem, direction, move_num)
        until new_elem == nil or new_elem.selectable
        if not new_elem or not new_elem.selectable then
            new_elem = last_selectable_elem
        end
    else
        -- first call, select first element no matter which direction was moved in
        new_elem = get_first_element(current_screen)
    end
    if new_elem then
        keyboard_navigation.select_element(new_elem)
    end
end

return keyboard_navigation
