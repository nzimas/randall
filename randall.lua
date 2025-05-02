-- Randall
-- Softcut randomizer
-- Select a root dir w/ samples
-- press k2 to rand samples
-- press k3 to rand params

-- Global variables
local sample_dir_root -- Managed by params
local available_samples = {}
local current_sample_path = {"", ""}
local current_sample_name = {"...", "..."}
local sample_duration = {0, 0}

local MAX_BUF_SECS = softcut.BUFFER_MAX_SECONDS or 349.0

-- Voice management
local active_voices = {1, 2} -- Voice for Buffer 1, Voice for Buffer 2
local inactive_voices = {3, 4}

local action_indicator = ""
local action_timer = nil
local crossfade_coroutine = nil -- To manage crossfade clock

local k1_down_time = nil
local k1_held_threshold = 0.5

-- Helper: check if path is likely a directory
local function is_likely_directory(path)
  if not path or path == "" then return false end
  local lower = string.lower(path)
  if lower:match("%.wav$") or lower:match("%.aif$") or lower:match("%.aiff$") then return false end
  if lower:match("%.flac$") or lower:match("%.ogg$") or lower:match("%.mp3$") or
     lower:match("%.alc$") or lower:match("%.asd$") or lower:match("%.json$") then return false end
  local ok, items = pcall(util.scandir, path)
  return (ok and items ~= nil)
end

-- Find WAV/AIF audio files recursively
function find_audio_files(current_path)
  local found_files = {}
  if not is_likely_directory(current_path) then print("Error: Invalid scan path: "..current_path); return {} end
  local items = util.scandir(current_path)
  if items then
    for _, item_name in ipairs(items) do -- Dirs first
      if not item_name:match("^%.") then
        local full_item_path = current_path .. "/" .. item_name
        if is_likely_directory(full_item_path) then
          local sub_dir_files = find_audio_files(full_item_path)
          for _, sub_file in ipairs(sub_dir_files) do table.insert(found_files, sub_file) end
        end
      end
    end
    for _, item_name in ipairs(items) do -- Then files
        if not item_name:match("^%.") then
          local full_item_path = current_path .. "/" .. item_name
          if not is_likely_directory(full_item_path) then
             local lower_item = string.lower(item_name)
             if lower_item:match("%.wav$") or lower_item:match("%.aif$") or lower_item:match("%.aiff$") then
               table.insert(found_files, full_item_path)
             end
          end
        end
    end
  end
  return found_files
end

-- Display action temporarily
function show_action(text)
    action_indicator = text
    if action_timer then clock.cancel(action_timer); action_timer = nil end
    action_timer = clock.run(function()
        clock.sleep(0.5); action_indicator = ""; action_timer = nil; redraw()
    end)
    redraw()
end

-- Helper: Get random value within parameter range
function get_random_param(min_id, max_id)
    local min_val = params:get(min_id); local max_val = params:get(max_id)
    if min_val > max_val then min_val = max_val end
    return math.random() * (max_val - min_val) + min_val
end

-- Helper: Get random integer within parameter range
function get_random_param_int(min_id, max_id)
    local min_val = params:get(min_id); local max_val = params:get(max_id)
    if min_val > max_val then min_val = max_val end
    if max_val < min_val then return min_val end
    return math.random(min_val, max_val)
end

-- Initiate crossfade between voice pairs
function start_crossfade()
    local old_v1 = active_voices[1]
    local old_v2 = active_voices[2]
    local new_v1 = inactive_voices[1]
    local new_v2 = inactive_voices[2]

    -- Get target levels from direct control params (these represent the desired audible level)
    local target_level1 = params:get("voice1_level")
    local target_level2 = params:get("voice2_level")

    local xfade_duration = params:get("crossfade_time")

    print(string.format("Crossfading: [%d,%d] -> 0 | [%d,%d] -> %.2f,%.2f over %.2fs",
                        old_v1, old_v2, new_v1, new_v2, target_level1, target_level2, xfade_duration))

    -- Cancel any previous crossfade coroutine
    if crossfade_coroutine then clock.cancel(crossfade_coroutine) end

    -- Start new crossfade coroutine
    crossfade_coroutine = clock.run(function()
        -- Set slew time for all voices involved
        softcut.level_slew_time(old_v1, xfade_duration)
        softcut.level_slew_time(old_v2, xfade_duration)
        softcut.level_slew_time(new_v1, xfade_duration)
        softcut.level_slew_time(new_v2, xfade_duration)

        -- Command the fades
        softcut.level(old_v1, 0)
        softcut.level(old_v2, 0)
        softcut.level(new_v1, target_level1)
        softcut.level(new_v2, target_level2)

        -- Wait for fade to complete
        clock.sleep(xfade_duration + 0.05) -- Add small buffer

        print("Crossfade complete. Disabling old voices: " .. old_v1 .. "," .. old_v2)
        -- Stop playback and potentially disable old voices (optional, level 0 might be enough)
        softcut.play(old_v1, 0)
        softcut.play(old_v2, 0)
        softcut.enable(old_v1, 0) -- Disable to save CPU?
        softcut.enable(old_v2, 0)

        -- Reset slew times for the now-active voices
        local level_slew_min = params:get("level_slew_min") -- Use randomized slew post-xfade
        local level_slew_max = params:get("level_slew_max")
        softcut.level_slew_time(new_v1, math.random()*(level_slew_max-level_slew_min)+level_slew_min)
        softcut.level_slew_time(new_v2, math.random()*(level_slew_max-level_slew_min)+level_slew_min)

        crossfade_coroutine = nil -- Mark as complete
    end)
end


-- Randomize parameters for a single voice using parameter ranges
function randomize_voice_params(voice_num)
  -- No need to print here, called frequently on K3 press
  local duration = sample_duration[voice_num == active_voices[1] and 1 or 2] -- Get duration for the *buffer* this voice uses
  if duration == nil or duration <= 0 then duration = MAX_BUF_SECS end

  local rate = get_random_param("rate_min", "rate_max"); if math.abs(rate) < 0.01 then rate = 0.01 * (rate >= 0 and 1 or -1) end
  softcut.rate(voice_num, rate)
  -- Level and Pan are randomized BUT immediately overwritten by direct controls when K3 is pressed
  -- If called during load, initial level is set to 0 before crossfade starts
  local level = get_random_param("level_min", "level_max")
  -- softcut.level(voice_num, level) -- Let direct control or crossfade handle this
  local pan = get_random_param("pan_min", "pan_max")
  softcut.pan(voice_num, pan)

  local start_pct = get_random_param("loop_start_min_pct", "loop_start_max_pct")
  local len_pct = get_random_param("loop_len_min_pct", "loop_len_max_pct")
  local loop_start = (start_pct / 100) * duration; local loop_end = loop_start + (len_pct / 100) * duration
  local min_loop_len_abs = 0.05
  loop_start = util.clamp(loop_start, 0, MAX_BUF_SECS); loop_end = util.clamp(loop_end, loop_start + min_loop_len_abs, MAX_BUF_SECS)
  softcut.loop_start(voice_num, loop_start); softcut.loop_end(voice_num, loop_end)
  softcut.position(voice_num, loop_start)

  -- Filters
  local filter_active = false; local fc = 0; local rq = 0; local filter_type = "DRY"
  if math.random(1, 3) ~= 1 then
    filter_active = true; softcut.pre_filter_dry(voice_num, 0); local filter_choice = math.random(1, 4)
    softcut.pre_filter_lp(voice_num, filter_choice == 1 and 1 or 0); if filter_choice == 1 then filter_type = "LP" end
    softcut.pre_filter_hp(voice_num, filter_choice == 2 and 1 or 0); if filter_choice == 2 then filter_type = "HP" end
    softcut.pre_filter_bp(voice_num, filter_choice == 3 and 1 or 0); if filter_choice == 3 then filter_type = "BP" end
    softcut.pre_filter_br(voice_num, filter_choice == 4 and 1 or 0); if filter_choice == 4 then filter_type = "BR" end
    fc = get_random_param_int("fc_min", "fc_max"); rq = get_random_param("rq_min", "rq_max")
    softcut.pre_filter_fc(voice_num, fc); softcut.pre_filter_rq(voice_num, rq)
  else
    softcut.pre_filter_dry(voice_num, 1); softcut.pre_filter_lp(voice_num, 0); softcut.pre_filter_hp(voice_num, 0);
    softcut.pre_filter_bp(voice_num, 0); softcut.pre_filter_br(voice_num, 0)
  end

  -- Slew/Fade times
  local rate_slew = get_random_param("rate_slew_min", "rate_slew_max")
  local level_slew = get_random_param("level_slew_min", "level_slew_max")
  local fade = get_random_param("fade_min", "fade_max")
  softcut.rate_slew_time(voice_num, rate_slew); softcut.level_slew_time(voice_num, level_slew)
  softcut.fade_time(voice_num, fade)

  -- Don't explicitly start playback here, let the load/crossfade logic handle it
  softcut.loop(voice_num, 1)
end


-- Function to load two new random samples with crossfade
function load_random_samples()
    local current_root = params:get("root_dir")
    print("Finding WAV/AIF samples in " .. current_root .. " ...")
    available_samples = find_audio_files(current_root)

    if #available_samples < 2 then
      print("Error: Need >= 2 WAV/AIF samples in specified directory.")
      show_action("Error: No Samples"); redraw()
      return
    end

    print("Found " .. #available_samples .. " WAV/AIF samples.")
    show_action("Loading...")

    -- Determine voice pairs
    local old_v1 = active_voices[1]
    local old_v2 = active_voices[2]
    local new_v1 = inactive_voices[1]
    local new_v2 = inactive_voices[2]

    -- Pick new samples
    local index1 = math.random(1, #available_samples); local index2 = math.random(1, #available_samples - 1)
    if index2 >= index1 then index2 = index2 + 1 end
    local next_sample_path1 = available_samples[index1]
    local next_sample_path2 = available_samples[index2]

    -- Update display names immediately
    current_sample_path[1] = next_sample_path1
    current_sample_path[2] = next_sample_path2
    current_sample_name[1] = string.match(current_sample_path[1], "([^/]+)$") or current_sample_path[1]
    current_sample_name[2] = string.match(current_sample_path[2], "([^/]+)$") or current_sample_path[2]
    redraw() -- Update screen to show new names

    print("Loading into Buffers 1 & 2 for Voices " .. new_v1 .. " & " .. new_v2)
    print("  New Sample 1: " .. current_sample_name[1])
    print("  New Sample 2: " .. current_sample_name[2])

    -- Assign new voices to buffers and enable them
    softcut.enable(new_v1, 1)
    softcut.enable(new_v2, 1)
    softcut.buffer(new_v1, 1)
    softcut.buffer(new_v2, 2)

    -- DON'T clear buffers - read will overwrite

    -- Initiate loading (overwrites buffers while old voices play)
    softcut.buffer_read_mono(current_sample_path[1], 0, 0, -1, 1, 1)
    softcut.buffer_read_mono(current_sample_path[2], 0, 0, -1, 1, 2)

    -- Reset temporary duration store
    sample_duration = {0, 0}

    -- Post-load actions in coroutine
    clock.run(function()
        clock.sleep(0.2)
        print("Waiting for buffers to load...")
        clock.sleep(params:get("load_wait_time")) -- Use parameter for wait time
        print("Buffers load initiated.")

        -- Get duration info for new samples
        local ch1, samples1, rate1 = audio.file_info(current_sample_path[1])
        local ch2, samples2, rate2 = audio.file_info(current_sample_path[2])
        if samples1 and rate1 and rate1 > 0 then sample_duration[1] = samples1 / rate1 else sample_duration[1] = 0 end
        if samples2 and rate2 and rate2 > 0 then sample_duration[2] = samples2 / rate2 else sample_duration[2] = 0 end
        print("New sample durations calculated: D1="..sample_duration[1]..", D2="..sample_duration[2])

        -- Prepare the *new* voices (inactive ones)
        print("Preparing new voices: " .. new_v1 .. "," .. new_v2)
        randomize_voice_params(new_v1)
        randomize_voice_params(new_v2)
        softcut.level(new_v1, 0) -- Ensure they start silent
        softcut.level(new_v2, 0)
        softcut.play(new_v1, 1) -- Start playback muted
        softcut.play(new_v2, 1)

        -- Start the crossfade
        start_crossfade() -- Will fade out active, fade in inactive

        -- Swap active/inactive roles for next time
        local temp_active = active_voices
        active_voices = inactive_voices
        inactive_voices = temp_active
        print("Active voices swapped to: " .. active_voices[1] .. "," .. active_voices[2])

        show_action("Samples Loaded!") -- Update indicator
        -- Redraw might be called by show_action already
    end)
end


function init()
  math.randomseed(os.time())
  print("randall init (v4.1 - Crossfade)")
  print("Using MAX_BUF_SECS = " .. MAX_BUF_SECS)

  -- === PARAMETERS ===
  -- Corrected group counts

  -- Randall Config group contains root_dir, crossfade_time, load_wait_time, separator = 4 items
  params:add_group("Randall Config", 4) -- <<< CORRECTED COUNT
  params:add_file("root_dir", "Sample Root Dir", _path.audio)
  params:set_action("root_dir", function(path)
      if is_likely_directory(path) then
          print("Sample root directory set to: " .. path)
      else
          local dir_name = string.match(path, "^(.*)/[^/]*$") or _path.audio
          if is_likely_directory(dir_name) then params:set("root_dir", dir_name)
          else params:set("root_dir", _path.audio) end
          print("Invalid dir, used parent or default: " .. params:get("root_dir"))
          show_action("Select Valid Dir!")
      end
  end)
  params:add_control("crossfade_time", "Crossfade Time (s)", controlspec.new(0.1, 5.0, 'lin', 0.1, 1.0))
  params:add_control("load_wait_time", "Load Wait Time (s)", controlspec.new(0.5, 5.0, 'lin', 0.1, 1.0)) -- Time to wait after load command
  params:add_separator()

  -- Direct Control group contains voice1_level, voice1_pan, voice2_level, voice2_pan = 4 items
  params:add_group("Direct Control", 4) -- This count was already correct
  -- These now control the *logically* first and second voices, which map to active_voices[1] and active_voices[2]
  params:add_control("voice1_level", "Voice 1 Level", controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("voice1_level", function(x) softcut.level(active_voices[1], x) end)
  params:add_control("voice1_pan", "Voice 1 Pan", controlspec.new(0, 1, 'lin', 0.01, 0.25))
  params:set_action("voice1_pan", function(x) softcut.pan(active_voices[1], x) end)
  params:add_control("voice2_level", "Voice 2 Level", controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("voice2_level", function(x) softcut.level(active_voices[2], x) end)
  params:add_control("voice2_pan", "Voice 2 Pan", controlspec.new(0, 1, 'lin', 0.01, 0.75))
  params:set_action("voice2_pan", function(x) softcut.pan(active_voices[2], x) end)

  -- Randomization Ranges group contains 23 items (controls + separators)
  params:add_group("Randomization Ranges", 23) -- <<< CORRECTED COUNT
  params:add_control("rate_min", "Rate Min", controlspec.new(-4, 4, 'lin', 0.01, -1.5)); params:add_control("rate_max", "Rate Max", controlspec.new(-4, 4, 'lin', 0.01, 1.5))
  params:add_control("level_min", "Level Min", controlspec.new(0, 1, 'lin', 0.01, 0.3)); params:add_control("level_max", "Level Max", controlspec.new(0, 1, 'lin', 0.01, 0.9))
  params:add_control("pan_min", "Pan Min", controlspec.new(0, 1, 'lin', 0.01, 0.0)); params:add_control("pan_max", "Pan Max", controlspec.new(0, 1, 'lin', 0.01, 1.0))
  params:add_separator("Loop (%)")
  params:add_control("loop_start_min_pct", "Start Min %", controlspec.new(0, 100, 'lin', 1, 0)); params:add_control("loop_start_max_pct", "Start Max %", controlspec.new(0, 100, 'lin', 1, 80))
  params:add_control("loop_len_min_pct", "Length Min %", controlspec.new(1, 100, 'lin', 1, 5)); params:add_control("loop_len_max_pct", "Length Max %", controlspec.new(1, 100, 'lin', 1, 50))
  params:add_separator("Filter")
  params:add_control("fc_min", "Filter FC Min (Hz)", controlspec.new(20, 12000, 'exp', 1, 100)); params:add_control("fc_max", "Filter FC Max (Hz)", controlspec.new(20, 12000, 'exp', 1, 10000))
  params:add_control("rq_min", "Filter RQ Min", controlspec.new(0.1, 20, 'lin', 0.1, 0.5)); params:add_control("rq_max", "Filter RQ Max", controlspec.new(0.1, 20, 'lin', 0.1, 8.0))
  params:add_separator("Timing (s)")
  params:add_control("rate_slew_min", "Rate Slew Min", controlspec.new(0.01, 2, 'exp', 0.01, 0.01)); params:add_control("rate_slew_max", "Rate Slew Max", controlspec.new(0.01, 2, 'exp', 0.01, 0.5))
  params:add_control("level_slew_min", "Level Slew Min", controlspec.new(0.01, 2, 'exp', 0.01, 0.01)); params:add_control("level_slew_max", "Level Slew Max", controlspec.new(0.01, 2, 'exp', 0.01, 0.5))
  params:add_control("fade_min", "Fade Min", controlspec.new(0.001, 0.5, 'exp', 0.001, 0.005)); params:add_control("fade_max", "Fade Max", controlspec.new(0.001, 0.5, 'exp', 0.001, 0.1))

  -- Set overall engine levels
  audio.level_cut(1.0)
  print("Set audio.level_cut to 1.0")

  -- Configure *all 4* softcut voices we might use
  for i = 1, 4 do
    softcut.enable(i, 1)
    softcut.buffer(i, (i % 2 == 1) and 1 or 2) -- Voices 1,3 use buffer 1; Voices 2,4 use buffer 2
    softcut.level(i, 0) -- Start all silent
    softcut.loop(i, 1); softcut.play(i, 0); softcut.rec_level(i, 0); softcut.pre_level(i, 1); softcut.fade_time(i, 0.05);
    -- Reset filters
    softcut.pre_filter_dry(i, 1.0); softcut.pre_filter_lp(i, 0.0); softcut.pre_filter_hp(i, 0.0);
    softcut.pre_filter_bp(i, 0.0); softcut.pre_filter_br(i, 0.0);
    softcut.post_filter_dry(i, 1.0); softcut.post_filter_lp(i, 0.0); softcut.post_filter_hp(i, 0.0);
    softcut.post_filter_bp(i, 0.0); softcut.post_filter_br(i, 0.0);
  end

  -- Set initial levels/pans for the initially active voices
  softcut.level(active_voices[1], params:get("voice1_level"))
  softcut.pan(active_voices[1], params:get("voice1_pan"))
  softcut.level(active_voices[2], params:get("voice2_level"))
  softcut.pan(active_voices[2], params:get("voice2_pan"))

  -- Load initial samples - this will randomize and play active_voices[1] & [2]
  load_random_samples()

  print("randall ready")
end

function key(n, z)
  -- K1 Long Press Logic
  if n == 1 then
    if z == 1 then k1_down_time = clock.time()
    else
      if k1_down_time ~= nil then
        if clock.time() - k1_down_time >= k1_held_threshold then
          print("K1 long press: Force play ACTIVE voices")
          softcut.play(active_voices[1], 1) -- Play currently active voices
          softcut.play(active_voices[2], 1)
          show_action("Play Triggered!")
        end
      end
      k1_down_time = nil
    end
  -- K2 Press: Load new samples and crossfade
  elseif n == 2 and z == 1 then
    load_random_samples()
  -- K3 Press: Randomize parameters of ACTIVE voices
  elseif n == 3 and z == 1 then
    show_action("Randomizing...")
    print("Randomizing active voices: " .. active_voices[1] .. "," .. active_voices[2])
    randomize_voice_params(active_voices[1])
    randomize_voice_params(active_voices[2])
    -- Re-apply direct controls to the *active* voices after randomization
    softcut.level(active_voices[1], params:get("voice1_level"))
    softcut.pan(active_voices[1], params:get("voice1_pan"))
    softcut.level(active_voices[2], params:get("voice2_level"))
    softcut.pan(active_voices[2], params:get("voice2_pan"))
    redraw()
  end
end

function enc(n, d)
  -- unused
end

function redraw()
  screen.clear(); screen.level(15); screen.move(0, 10); screen.text("randall v4.1") -- Version bump
  screen.move(0, 25); screen.text("1: " .. current_sample_name[1])
  screen.move(0, 35); screen.text("2: " .. current_sample_name[2])
  screen.move(0, 50); screen.text("K2: New Samples"); screen.move(0, 60); screen.text("K3: Randomize")
  screen.level(4); screen.move(64, 60); screen.text_center("(K1 hold: Play)")
  if action_indicator ~= "" then
      screen.level(8); screen.move(0, 10); screen.text_right(action_indicator); screen.level(15)
  end
  screen.update()
end

-- Cleanup function
function cleanup()
    print("Stopping randall...")
    if action_timer then clock.cancel(action_timer); action_timer = nil end
    if crossfade_coroutine then clock.cancel(crossfade_coroutine); crossfade_coroutine = nil end
    -- Stop and reset all 4 potentially used voices
    for i=1,4 do
      softcut.play(i,0); softcut.level(i,0);
      softcut.enable(i,0); -- Disable voices on cleanup
      -- Reset filters (optional but clean)
      softcut.pre_filter_dry(i, 1.0); softcut.pre_filter_lp(i, 0.0); softcut.pre_filter_hp(i, 0.0);
      softcut.pre_filter_bp(i, 0.0); softcut.pre_filter_br(i, 0.0);
    end
    audio.level_cut(0)
    print("randall stopped.")
end
