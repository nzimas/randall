-- randall.lua (v3.1)
-- Fix audio.file_info call, add K1 long-press play trigger

-- Global variables
local sample_dir_root = _path.audio
local available_samples = {}
local current_sample_path = {"", ""}
local current_sample_name = {"...", "..."}
local sample_duration = {0, 0} -- Store actual duration if possible

local MAX_BUF_SECS = softcut.BUFFER_MAX_SECONDS or 349.0

local action_indicator = ""
local action_timer = nil

-- Variables for K1 long-press detection
local k1_down_time = nil
local k1_held_threshold = 0.5 -- seconds to hold for long-press action

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
  local items = util.scandir(current_path)
  if items then
    -- Pass 1: Dirs
    for _, item_name in ipairs(items) do
      if not item_name:match("^%.") then
        local full_item_path = current_path .. "/" .. item_name
        if is_likely_directory(full_item_path) then
          local sub_dir_files = find_audio_files(full_item_path)
          for _, sub_file in ipairs(sub_dir_files) do table.insert(found_files, sub_file) end
        end
      end
    end
    -- Pass 2: Files
    for _, item_name in ipairs(items) do
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

-- Randomize parameters for a single voice
function randomize_voice_params(voice_num)
  print("Randomizing voice " .. voice_num .. "...")
  local duration = sample_duration[voice_num]
  if duration == nil or duration <= 0 then
      print("  Voice " .. voice_num .. " using MAX_BUF_SECS (" .. MAX_BUF_SECS .. ") for loop points.")
      duration = MAX_BUF_SECS
  else
      print("  Voice " .. voice_num .. " using actual duration (" .. string.format("%.2f", duration) .. ") for loop points.")
  end

  -- Rate
  local rate = math.pow(2, math.random(-250, 250) / 50); if math.random(1, 5) == 1 then rate = rate * -1 end
  if math.abs(rate) < 0.01 then rate = 0.01 * (rate >= 0 and 1 or -1) end
  softcut.rate(voice_num, rate)
  -- Level
  local level = math.random(30, 100) / 100
  softcut.level(voice_num, level)
  -- Pan
  softcut.pan(voice_num, math.random())
  -- Loop points
  local loop_start = math.random() * duration; local loop_end = math.random() * duration
  if loop_end < loop_start then local temp = loop_start; loop_start = loop_end; loop_end = temp end
  local min_loop_len = 0.05
  if loop_end - loop_start < min_loop_len then loop_end = loop_start + min_loop_len end
  loop_start = util.clamp(loop_start, 0, MAX_BUF_SECS); loop_end = util.clamp(loop_end, loop_start, MAX_BUF_SECS)
  softcut.loop_start(voice_num, loop_start); softcut.loop_end(voice_num, loop_end)
  softcut.position(voice_num, loop_start)

  -- Filters
  local filter_active = false; local fc = 0; local rq = 0; local filter_type = "DRY"
  if math.random(1, 3) ~= 1 then
    filter_active = true
    softcut.pre_filter_dry(voice_num, 0); local filter_choice = math.random(1, 4)
    softcut.pre_filter_lp(voice_num, filter_choice == 1 and 1 or 0); if filter_choice == 1 then filter_type = "LP" end
    softcut.pre_filter_hp(voice_num, filter_choice == 2 and 1 or 0); if filter_choice == 2 then filter_type = "HP" end
    softcut.pre_filter_bp(voice_num, filter_choice == 3 and 1 or 0); if filter_choice == 3 then filter_type = "BP" end
    softcut.pre_filter_br(voice_num, filter_choice == 4 and 1 or 0); if filter_choice == 4 then filter_type = "BR" end
    fc = math.random(50, 12000); softcut.pre_filter_fc(voice_num, fc)
    rq = math.random(1, 150) / 10; softcut.pre_filter_rq(voice_num, rq)
  else
    softcut.pre_filter_dry(voice_num, 1); softcut.pre_filter_lp(voice_num, 0); softcut.pre_filter_hp(voice_num, 0);
    softcut.pre_filter_bp(voice_num, 0); softcut.pre_filter_br(voice_num, 0)
  end

  -- Slew/Fade times
  local rate_slew = math.random(1, 50) / 100; local level_slew = math.random(1, 50) / 100
  local fade = math.random(1, 100) / 1000
  softcut.rate_slew_time(voice_num, rate_slew); softcut.level_slew_time(voice_num, level_slew)
  softcut.fade_time(voice_num, fade)

  -- Debug Print
  print(string.format("  Voice %d: rate=%.2f, level=%.2f, loop=%.2f-%.2f, filter=%s (active=%s, fc=%d, rq=%.1f), fade=%.3f",
                      voice_num, rate, level, loop_start, loop_end, filter_type, tostring(filter_active), fc, rq, fade))

  -- Ensure playback is on
  softcut.loop(voice_num, 1); softcut.play(voice_num, 1)
end


-- Function to load two new random samples
function load_random_samples()
  print("Finding WAV/AIF samples in " .. sample_dir_root .. " ...")
  available_samples = find_audio_files(sample_dir_root)

  if #available_samples < 2 then
    print("Error: Need >= 2 WAV/AIF samples in " .. sample_dir_root); show_action("Error: No Samples"); redraw()
    softcut.play(1, 0); softcut.play(2, 0); current_sample_name = {"Error", "Error"}; current_sample_path = {"", ""}
    return
  end

  print("Found " .. #available_samples .. " WAV/AIF samples.")
  show_action("Loading...")

  -- Pick indices
  local index1 = math.random(1, #available_samples); local index2 = math.random(1, #available_samples - 1)
  if index2 >= index1 then index2 = index2 + 1 end

  current_sample_path[1] = available_samples[index1]; current_sample_path[2] = available_samples[index2]
  current_sample_name[1] = string.match(current_sample_path[1], "([^/]+)$") or current_sample_path[1]
  current_sample_name[2] = string.match(current_sample_path[2], "([^/]+)$") or current_sample_path[2]
  sample_duration = {0, 0} -- Reset durations

  print("Loading sample 1: " .. current_sample_name[1]); print("Loading sample 2: " .. current_sample_name[2])

  -- Stop playback
  softcut.play(1, 0); softcut.play(2, 0)
  -- Clear buffers
  softcut.buffer_clear(1); softcut.buffer_clear(2)
  -- Initiate loading
  softcut.buffer_read_mono(current_sample_path[1], 0, 0, -1, 1, 1)
  softcut.buffer_read_mono(current_sample_path[2], 0, 0, -1, 1, 2)

  -- Actions after loading commands (run in coroutine)
  clock.run(function()
      clock.sleep(0.2) -- Brief initial wait
      print("Waiting for buffers to load...")
      clock.sleep(1.0) -- Main wait for disk I/O
      print("Buffers load initiated.")

      -- *** Get file info correctly ***
      local ch1, samples1, rate1 = audio.file_info(current_sample_path[1])
      local ch2, samples2, rate2 = audio.file_info(current_sample_path[2])

      -- Calculate and store duration if info is valid
      if samples1 and rate1 and rate1 > 0 then
          sample_duration[1] = samples1 / rate1
          print("Buffer 1 sample duration: " .. string.format("%.2f", sample_duration[1]))
      else
          print("Could not get valid info for buffer 1 sample.")
          sample_duration[1] = 0 -- Indicate failure (will use MAX_BUF_SECS)
      end
      if samples2 and rate2 and rate2 > 0 then
          sample_duration[2] = samples2 / rate2
          print("Buffer 2 sample duration: " .. string.format("%.2f", sample_duration[2]))
      else
           print("Could not get valid info for buffer 2 sample.")
           sample_duration[2] = 0 -- Indicate failure (will use MAX_BUF_SECS)
      end

      -- Initial randomization
      randomize_voice_params(1)
      randomize_voice_params(2)
      show_action("Samples Loaded!")
      redraw()
  end)
end


function init()
  math.randomseed(os.time())
  print("randall init (v3.1)")
  print("Using MAX_BUF_SECS = " .. MAX_BUF_SECS)
  audio.level_cut(1.0)
  print("Set audio.level_cut to 1.0")

  for i = 1, 2 do
    softcut.enable(i, 1); softcut.buffer(i, i); softcut.loop(i, 1); softcut.level(i, 0);
    softcut.play(i, 0); softcut.rec_level(i, 0); softcut.pre_level(i, 1); softcut.fade_time(i, 0.05);
    softcut.pre_filter_dry(i, 1.0); softcut.pre_filter_lp(i, 0.0); softcut.pre_filter_hp(i, 0.0);
    softcut.pre_filter_bp(i, 0.0); softcut.pre_filter_br(i, 0.0); softcut.post_filter_dry(i, 1.0);
    softcut.post_filter_lp(i, 0.0); softcut.post_filter_hp(i, 0.0); softcut.post_filter_bp(i, 0.0);
    softcut.post_filter_br(i, 0.0);
  end

  load_random_samples()
  print("randall ready")
end

function key(n, z)
  -- K1 Long Press Logic
  if n == 1 then
    if z == 1 then
      -- Key 1 pressed down, record time
      k1_down_time = clock.time()
    else
      -- Key 1 released
      if k1_down_time ~= nil then
        local hold_duration = clock.time() - k1_down_time
        if hold_duration >= k1_held_threshold then
          -- Long press action: Force play both voices
          print("K1 long press: Force play voices 1 & 2")
          softcut.play(1, 1)
          softcut.play(2, 1)
          show_action("Play Triggered!")
        else
          -- Short press action (if any needed in future)
          print("K1 short press detected (no action)")
        end
      end
      k1_down_time = nil -- Reset timer
    end
  -- K2 Press: Load new samples
  elseif n == 2 and z == 1 then
    load_random_samples()
  -- K3 Press: Randomize parameters
  elseif n == 3 and z == 1 then
    show_action("Randomizing...")
    randomize_voice_params(1)
    randomize_voice_params(2)
    redraw()
  end
end

function enc(n, d)
  -- unused
end

function redraw()
  screen.clear(); screen.level(15); screen.move(0, 10); screen.text("randall v3.1") -- Version bump
  screen.move(0, 25); screen.text("1: " .. current_sample_name[1])
  screen.move(0, 35); screen.text("2: " .. current_sample_name[2])
  screen.move(0, 50); screen.text("K2: New Samples"); screen.move(0, 60); screen.text("K3: Randomize")
  -- Add K1 long press info
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
    for i=1,2 do
      softcut.play(i,0); softcut.level(i,0);
      softcut.pre_filter_dry(i, 1.0); softcut.pre_filter_lp(i, 0.0); softcut.pre_filter_hp(i, 0.0);
      softcut.pre_filter_bp(i, 0.0); softcut.pre_filter_br(i, 0.0);
    end
    audio.level_cut(0)
    print("randall stopped.")
end
