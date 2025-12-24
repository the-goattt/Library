--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

type Cleanup = () -> ()

type Heartbeat = {
	Connect: (self: Heartbeat, callback: (deltaTime: number) -> ()) -> Disconnectable,
}

type Disconnectable = {
	Disconnect: (self: Disconnectable) -> (),
}

type Partial<T> = { [any]: any } & T

type SpringOptions = {
	damping: number?,
	frequency: number?,
	mass: number?,
	tension: number?,
	friction: number?,
	position: number?,
	velocity: number?,
	impulse: number?,
	restingVelocity: number?,
	restingPosition: number?,
}

type MotionOptions = {
	heartbeat: Heartbeat?,
	start: boolean?,
}

type MotionState = {
	value: number,
	complete: boolean,
	velocity: number?,
	destructor: (() -> ())?,
}

type MotionSolver = (key: unknown, state: MotionState, deltaTime: number) -> ()

type MotionGoal = { [any]: number } | number | UDim2 | UDim | Vector2 | Vector3 | Color3 | CFrame

type Motion<T = number> = {
	state: { [any]: MotionState },
	start: (self: Motion<T>) -> Cleanup,
	stop: (self: Motion<T>) -> (),
	get: (self: Motion<T>) -> T,
	set: (self: Motion<T>, value: T | { [any]: number }) -> (),
	getVelocity: (self: Motion<T>) -> T,
	setVelocity: (self: Motion<T>, value: T | { [any]: number }) -> (),
	impulse: (self: Motion<T>, impulse: T | { [any]: number }) -> (),
	patch: (self: Motion<T>, patch: { [any]: Partial<MotionState> }) -> (),
	to: (self: Motion<T>, goal: MotionSolver | { [any]: MotionSolver }) -> (),
	spring: (self: Motion<T>, goal: T, options: SpringOptions?) -> (),
	step: (self: Motion<T>, deltaTime: number) -> T,
	isComplete: (self: Motion<T>) -> boolean,
	onComplete: (self: Motion<T>, callback: (value: T) -> ()) -> Cleanup,
	onStep: (self: Motion<T>, callback: (value: T, deltaTime: number) -> ()) -> Cleanup,
	destroy: (self: Motion<T>) -> (),
}

local ripple do
	local config = {
		spring = {
			default = { tension = 170, friction = 26 },
			gentle = { tension = 120, friction = 14 },
			wobbly = { tension = 180, friction = 12 },
			stiff = { tension = 210, friction = 20 },
			slow = { tension = 280, friction = 60 },
			molasses = { tension = 280, friction = 120 },
		},
	}

	type Intermediate = { [any]: number }

	local intermediates = {
		number = {
			to = function(value: number): Intermediate
				return { value }
			end,
			from = function(value: Intermediate): number
				return value[1]
			end,
		},

		table = {
			to = function(value: Intermediate): Intermediate
				return value
			end,
			from = function(value: Intermediate): Intermediate
				return value
			end,
		},

		UDim2 = {
			to = function(value: UDim2): Intermediate
				return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
			end,
			from = function(value: Intermediate): UDim2
				return UDim2.new(value[1], math.round(value[2]), value[3], math.round(value[4]))
			end,
		},

		UDim = {
			to = function(value: UDim): Intermediate
				return { value.Scale, value.Offset }
			end,
			from = function(value: Intermediate)
				return UDim.new(value[1], math.round(value[2]))
			end,
		},

		Vector2 = {
			to = function(value: Vector2): Intermediate
				return { value.X, value.Y }
			end,
			from = function(value: Intermediate): Vector2
				return Vector2.new(table.unpack(value, 1, 2))
			end,
		},

		Vector3 = {
			to = function(value: Vector3): Intermediate
				return { value.X, value.Y, value.Z }
			end,
			from = function(value: Intermediate): Vector3
				return Vector3.new(table.unpack(value, 1, 3))
			end,
		},

		Color3 = {
			to = function(value: Color3): Intermediate
				return { value.R, value.G, value.B }
			end,
			from = function(value: Intermediate): Color3
				return Color3.new(math.clamp(value[1], 0, 1), math.clamp(value[2], 0, 1), math.clamp(value[3], 0, 1))
			end,
		},

		CFrame = {
			to = function(value: CFrame): Intermediate
				return { value:GetComponents() }
			end,
			from = function(value: Intermediate): CFrame
				return CFrame.new(table.unpack(value))
			end,
		},
	}

	local function to(value: unknown): Intermediate
		local type = typeof(value)

		if intermediates[type] then
			return intermediates[type].to(value)
		else
			error(`Ripple received an unsupported value '{value}' of type '{type}'`)
		end
	end

	local function from<T>(value: Intermediate, type: string): T
		if intermediates[type] then
			return intermediates[type].from(value)
		else
			error(`Ripple received an unsupported value '{value}' of type '{type}'`)
		end
	end

	local function index(value: Intermediate, key: unknown): number?
		return value[key] or value[1]
	end

	local intermediate = {
		to = to,
		from = from,
		index = index,
	}

	local STEP = 1 -- milliseconds
	local MAX_PASS = 100

	local function configure(options: SpringOptions)
		local mass = options.mass or 1
		local tension = options.tension or config.spring.default.tension
		local friction = options.friction or config.spring.default.friction

		if options.frequency or options.damping then
			local frequency = options.frequency or 0.5
			local damping = options.damping or 1
			tension = (2 * math.pi / frequency) ^ 2 * mass
			friction = (4 * math.pi * damping * mass) / frequency
		end

		return {
			mass = mass,
			tension = tension,
			friction = friction,
			position = options.position,
			velocity = options.velocity,
			impulse = options.impulse,
			restingVelocity = options.restingVelocity or 0.001,
			restingPosition = options.restingPosition or 0.0001,
		}
	end

	local function spring(motionGoal: MotionGoal, options: SpringOptions?): MotionSolver
		local props = configure(options or {})
		local goals = intermediate.to(motionGoal)
		local mounting = true

		return function(key, state, deltaTime)
			local goal = intermediate.index(goals, key)

			if not goal then
				return false
			end

			if mounting then
				mounting = false
				state.value = (props.position or state.value or 0)
				state.velocity = (props.velocity or state.velocity or 0) + (props.impulse or 0)
			end

			local position = state.value
			local velocity = state.velocity or 0
			local passes = math.min(math.ceil((deltaTime * 1000) / STEP), MAX_PASS)

			for _ = 1, passes do
				local springForce = -props.tension * 0.000001 * (position - goal)
				local dampingForce = -props.friction * 0.001 * velocity
				local acceleration = (springForce + dampingForce) / props.mass

				velocity += acceleration * STEP
				position += velocity * STEP
			end

			if math.abs(velocity) < props.restingVelocity and math.abs(position - goal) < props.restingPosition then
				state.complete = true
				state.value = goal
				state.velocity = 0
			else
				state.value = position
				state.velocity = velocity
			end
		end
	end

	local RunService = game:GetService("RunService")

	local springSolver = spring

	local function assign<T>(object: T, ...: { [any]: any }): T
		assert(type(object) == "table", `Expected a table for first argument, got ${type(object)}`)

		for index = 1, select("#", ...) do
			local source = select(index, ...)

			for key, value in source do
				object[key] = value
			end
		end

		return object
	end

	local function merge<T, U>(a: T & { [any]: any }, b: U & { [any]: any }): T & U
		local copy = table.clone(a)

		for key, value in pairs(b) do
			copy[key] = value
		end

		return copy :: never
	end

	local defaults = {
		heartbeat = RunService.Heartbeat,
		start = false,
	}

	local function createMotion<T>(initialValue: T, options: MotionOptions?): Motion<T>
		local config = merge(defaults, options or {})
		local valueType = typeof(initialValue)

		local motionState: { [any]: MotionState } = {}
		local motionSolvers: { [any]: MotionSolver } = {}

		local onStepListeners: { (value: T, deltaTime: number) -> () } = {}
		local onCompleteListeners: { (value: T) -> () } = {}
		local nextListenerId = 1

		local connection: RBXScriptConnection?
		local wasComplete = false
		local lastCompleteValue

		for key, value in intermediate.to(initialValue) do
			motionState[key] = {
				value = value,
				complete = true,
			}
		end

		local function stop()
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end

		local function start(self)
			if connection then
				return stop
			end

			connection = config.heartbeat:Connect(function(deltaTime)
				self:step(deltaTime)
			end)

			return stop
		end

		local function get()
			local intermediates = {}

			for key, state in motionState do
				intermediates[key] = state.value
			end

			return intermediate.from(intermediates, valueType)
		end

		local function getVelocity()
			local intermediates = {}

			for key, state in motionState do
				intermediates[key] = state.velocity or 0
			end

			return intermediate.from(intermediates, valueType)
		end

		local function set(_self, value)
			local intermediates = intermediate.to(value)

			for key, state in motionState do
				local newValue = intermediates[key]

				if newValue then
					state.value = newValue
					state.complete = false
				end
			end
		end

		local function patch(_self, source)
			for key, state in motionState do
				local stateSource = source[key]

				if stateSource then
					state.complete = false
					assign(state, stateSource)
				end
			end
		end

		local function impulse(_self, impulses)
			if type(impulses) == "number" then
				for _, state in motionState do
					if not state.velocity then
						continue
					end

					state.complete = false
					state.velocity += impulses
				end

				return
			end

			local intermediateImpulses = intermediate.to(impulses)

			for key, amount in intermediateImpulses do
				local state = motionState[key]

				if not state or not state.velocity then
					continue
				end

				state.complete = false
				state.velocity += amount
			end
		end

		local function setVelocity(_self, velocity)
			local intermediates = intermediate.to(velocity)

			for key, amount in intermediates do
				local state = motionState[key]

				if not state or not state.velocity then
					continue
				end

				state.complete = false
				state.velocity = amount
			end
		end

		local function to(_self, solvers)
			if type(solvers) == "function" then
				for key, state in motionState do
					if state.destructor then
						state.destructor()
						state.destructor = nil
					end

					state.complete = false

					if solvers(key, state, 0) ~= false then
						-- only sets the solver if this key is part of the new goal
						motionSolvers[key] = solvers
					end
				end

				return
			end

			for key, solver in solvers do
				local state = motionState[key]

				if not state then
					continue
				end

				if state.destructor then
					state.destructor()
					state.destructor = nil
				end

				state.complete = false

				if solver(key, state, 0) ~= false then
					-- only sets the solver if this key is part of the new goal
					motionSolvers[key] = solver
				end
			end
		end

		local function spring(self, value, params)
			self:to(springSolver(value :: any, params))
		end

		local function step(self, deltaTime)
			for key, handler in motionSolvers do
				local state = motionState[key]

				if state and not state.complete then
					handler(key, state, deltaTime)
				end
			end

			local value = self:get()
			local complete = self:isComplete()

			if not complete or not wasComplete or lastCompleteValue ~= value then
				for _, listener in onStepListeners do
					task.spawn(listener, value, deltaTime)
				end
			end

			if complete and (not wasComplete or lastCompleteValue ~= value) then
				for _, listener in onCompleteListeners do
					task.spawn(listener, value)
				end
			end

			wasComplete = complete
			lastCompleteValue = value

			return value
		end

		local function isComplete()
			for _, state in motionState do
				if not state.complete then
					return false
				end
			end

			return true
		end

		local function onComplete(_self, callback)
			local listenerId = nextListenerId
			nextListenerId += 1
			onCompleteListeners[listenerId] = callback

			return function()
				onCompleteListeners[listenerId] = nil
			end
		end

		local function onStep(_self, callback)
			local listenerId = nextListenerId
			nextListenerId += 1
			onStepListeners[listenerId] = callback

			return function()
				onStepListeners[listenerId] = nil
			end
		end

		local function destroy()
			wasComplete = false
			nextListenerId = 1

			stop()

			table.clear(onStepListeners)
			table.clear(onCompleteListeners)
			table.clear(motionSolvers)

			for _, state in motionState do
				if state.destructor then
					state.destructor()
					state.destructor = nil
				end
			end
		end

		local motion: Motion<T> = {
			state = motionState,
			start = start,
			stop = stop,
			get = get,
			set = set,
			getVelocity = getVelocity,
			setVelocity = setVelocity,
			impulse = impulse,
			patch = patch,
			to = to,
			spring = spring,
			step = step,
			isComplete = isComplete,
			onComplete = onComplete,
			onStep = onStep,
			destroy = destroy,
		}

		if config.start then
			motion:start()
		end

		return motion
	end

	ripple = { create_motion = createMotion }
end

export type Library = {
	Registry: Registry,
	Window: (self: Library, props: WindowProps) -> Window,
}

type Source<V> = {
	kind: "source",

	fire_listeners: (self: Source<V>) -> (),
	listen: (self: Source<V>, callback: (V) -> ()) -> () -> (),
	get: (self: Source<V>) -> V,
	set: (self: Source<V>, value: V) -> (),
}

type Theme = string
type ThemeTag = string
type Property = string
type ThemeData = { [ThemeTag]: { [Property]: any } }

export type Registry = {
	motions: { Motion<any> },
	motion_connection: RBXScriptConnection,
	windows: { Window },
}

export type Notification = {
	Destroy: (self: Notification) -> (),
	Close: (self: Notification) -> (),

	window: Window,
	thread: thread,
	instance: Frame,
}

export type NotificationProps = {
	Title: string,
	Text: string,
	Duration: number?,
}

export type SerializedTheme = string

export type Window = {
	Tab: (self: Window, props: TabProps) -> Tab,
	Notify: (self: Window, props: NotificationProps) -> Notification,

	Minimize: (self: Window) -> (),
	Maximize: (self: Window) -> (),
	ToggleMinimized: (self: Window) -> (),
	Minimized: boolean,

	Destroy: (self: Window) -> (),
	OnClose: (self: Window) -> (),

	SaveConfig: (self: Window, name: string?) -> (),
	GetConfig: (self: Window) -> string,
	LoadConfig: (self: Window, name: string?) -> (),
	GetConfigs: (self: Window) -> { [string]: string },

	LoadTheme: (self: Window, name: string) -> (),
	AddTheme: (self: Window, name: string, theme: ThemeData) -> SerializedTheme,
	GetThemes: (self: Window, name: string) -> { [string]: ThemeData },
	LoadThemes: (self: Window) -> { [string]: ThemeData },

	Flags: { [string]: Element },

	window_position: UDim2, 

	title: string,
	config_folder: string,

	container: ImageLabel,
	content_container: Frame,
	sidebar: Frame,

	tabs: { Tab },
	selected_tab: Source<Tab>,

	tab_order: number,

	theme_changed: (self: Window, () -> ()) -> () -> (),

	theme: Theme,
	themes: { [Theme]: ThemeData },
	theme_instances: { [ThemeTag]: { Instance } },

	notifications: { Notification },

	cleanups: { () -> () },
}

export type WindowProps = {
	Title: string,
	Icon: string,
	Folder: string?,
	MinimizeKey: Enum.KeyCode?,
}

export type Tab = {
	Section: (self: Tab, props: SectionProps) -> Section,

	window: Window,
	selected: Source<boolean>,

	title: string,
	icon: string,

	content: ScrollingFrame,
	instance: CanvasGroup,

	section_transparency: Motion<number>,
	section_order: number,
}

export type TabProps = {
	Title: string,
	Icon: string,

	Order: number?,
}

export type Section = {
	Input: (self: Section, props: InputProps) -> Input,
	Button: (self: Section, props: ButtonProps) -> Button,
	Toggle: (self: Section, props: ToggleProps) -> Toggle,
	Divider: (self: Section, props: DividerProps) -> Divider,
	Slider: (self: Section, props: SliderProps) -> Slider,
	Keybind: (self: Section, props: KeybindProps) -> Keybind,
	RangeSlider: (self: Section, props: RangeSliderProps) -> RangeSlider,
	ColorPicker: (self: Section, props: ColorPickerProps) -> ColorPicker,
	Dropdown: (self: Dropdown, props: DropdownProps) -> Dropdown,

	window: Window,
	tab: Tab,

	instance: Frame,
	container: Frame,

	visible: Source<boolean>,

	title: string,
	content_transparency: Motion<number>,

	box_bg_transparency: Motion<number>,
	element_bg_transparency: Motion<number>,
	element_stroke_transparency: Motion<number>,

	content_order: number,
	elements: { Element },
}

export type SectionProps = {
	Title: string,

	Order: number?,
}

export type Button = {
	kind: "button",

	Listen: (self: Button, callback: () -> ()) -> () -> (),

	window: Window,
	tab: Tab,
	section: Section,

	title: string,
	callbacks: { () -> () },

	instance: TextButton,
}

export type InfoBox = {
	kind: "infobox",

	Listen: (self: InfoBox, callback: () -> ()) -> () -> (),

	window: Window,
	tab: Tab,
	section: Section,

	title: string,
	content: string,

	instance: TextButton,
}

export type Input = {
	kind: "input",

	Listen: (self: Input, callback: (string) -> ()) -> () -> (),
	Value: Source<string>,

	window: Window,
	tab: Tab,
	section: Section,

	title: string,
	callbacks: { (string) -> () },

	instance: Frame,
}

export type Toggle = {
	kind: "toggle",

	Listen: (self: Toggle, callback: (Value: boolean) -> ()) -> () -> (),
	Value: Source<boolean>,

	window: Window,
	tab: Tab,
	section: Section,

	title: string,
	default_value: boolean,
	callbacks: { (Value: boolean) -> () },

	instance: TextButton,
}

export type ToggleProps = {
	Title: string,
	DefaultValue: boolean,
	Callback: ((Value: boolean) -> ())?,

	Flag: string?,
	Order: number?,
}

export type ButtonProps = {
	Title: string,
	Callback: (() -> ())?,

	Flag: string?,
	Order: number?,
}

export type InfoBoxProps = {
	Title: string,
	Content: string,
	
	SetContent: (self: InfoBox, content: { string }) -> (),

	Flag: string?,
	Order: number?,
}

export type InputProps = {
	Title: string,
	DefaultValue: string,
	Callback: ((Value: string) -> ())?,
	PlaceholderText: string,

	Flag: string?,
	Order: number?,
}

export type Divider = {
	kind: "divider",

	window: Window,
	tab: Tab,
	section: Section,

	instance: Frame,
}

export type DividerProps = {
	Order: number?,
}?

export type Slider = {
	kind: "slider",

	Listen: (self: Slider, callback: (Value: number) -> ()) -> () -> (),
	Value: Source<number>,

	window: Window,
	tab: Tab,
	section: Section,

	min: number,
	max: number,

	instance: Frame,
}

export type SliderProps = {
	Title: string,
	DefaultValue: number,
	Min: number,
	Max: number,
	Precision: number?,
	Callback: ((Value: number) -> ())?,

	Flag: string?,
	Order: number?,
}

export type Keybind = {
	kind: "keybind",

	Listen: (self: Keybind, callback: (Value: Enum.KeyCode) -> ()) -> () -> (),
	Value: Source<Enum.KeyCode>,

	window: Window,
	tab: Tab,
	section: Section,

	instance: Frame,
}

export type KeybindProps = {
	Title: string,
	DefaultValue: Enum.KeyCode,
	BlacklistedKeys: { Enum.KeyCode }?,
	Callback: ((Value: Enum.KeyCode) -> ())?,

	Flag: string?,
	Order: number?,
}

export type RangeSlider = {
	kind: "range_slider",

	Listen: (self: RangeSlider, callback: (Range: vector) -> ()) -> () -> (),
	Value: Source<vector>,

	window: Window,
	tab: Tab,
	section: Section,

	min: number,
	max: number,

	instance: Frame,
}

export type RangeSliderProps = {
	Title: string,
	DefaultValue: vector | Vector2 | Vector3,
	Min: number,
	Max: number,
	Precision: number?,
	Callback: ((Range: vector) -> ())?,

	Flag: string?,
	Order: number?,
}

export type ColorPicker = {
	kind: "color_picker",

	Listen: (self: ColorPicker, callback: (Color: Color3) -> ()) -> () -> (),
	Value: Source<Color3>,

	window: Window,
	tab: Tab,
	section: Section,

	instance: Frame,
}

export type ColorPickerProps = {
	Title: string,
	DefaultValue: Color3,
	Callback: ((Color: Color3) -> ())?,

	Flag: string?,
	Order: number?,
}

export type Dropdown = {
	kind: "dropdown",

	Listen: (self: Dropdown, callback: (Selected: string) -> ()) -> () -> (),
	Value: Source<string>,

	Open: (self: Dropdown) -> (),
	Close: (self: Dropdown) -> (),
	Toggle: (self: Dropdown) -> (),
	IsOpen: boolean,
	Multi: boolean,

	SetItems: (self: Dropdown, items: { string }) -> (),

	items: { string },

	window: Window,
	tab: Tab,
	section: Section,

	instance: Frame,
}

export type DropdownProps<Value = string> = {
	Title: string,
	DefaultValue: Value,
	Items: { string },
	Callback: ((Selected: Value) -> ())?,
	Multi: boolean,

	Flag: string?,
	Order: number?,
}

export type MultiDropdownProps = DropdownProps<{string}> & { Multi: true }

export type Element = Toggle | Divider | Slider | Keybind | RangeSlider | ColorPicker | Dropdown | Button | Input |InfoBox

local DEFAULT_MINIMIZE_KEY = Enum.KeyCode.LeftAlt

local reg_motions: { Motion<any> } = setmetatable({}, { __mode = "v" }) :: any
local registry: Registry

local function AWAKEN_MOTION()
	registry.motion_connection = RunService.Heartbeat:Connect(function(dt)
		if #reg_motions == 0 then
			-- if everything is gc'd then stop the connection
			registry.motion_connection:Disconnect()
			return
		end

		for _, motion in reg_motions do
			motion:step(dt)
		end
	end)
end

local ICON, ICON_BLUR = 'https://raw.githubusercontent.com/LovelySoftworksLLC/Lovely/refs/heads/main/SLR2/lovely_icon.png', "https://raw.githubusercontent.com/LovelySoftworksLLC/Lovely/refs/heads/main/SLR2/lovely_icon_blurred.png"
local DEFAULT_THEMES = {
	Dark = {
		-- TEXT COLORS
		Primary = {TextColor3 = Color3.fromRGB(235, 235, 235),},
		Secondary = {TextColor3 = Color3.fromRGB(200, 200, 200),},

		-- the rest of the stuff.
		WindowShadow = {
			ImageColor3 = Color3.fromRGB(0, 0, 0),
			ImageTransparency = 0.7,
		},
		WindowStroke = {
			Color = Color3.fromRGB(255, 255, 255),
			Thickness = 1.2,
			Transparency = 0.95,
		},

		Topbar = {
			BackgroundColor3 = Color3.fromRGB(17,18,19),
			BackgroundTransparency = 0,
		},
		TopbarIcon = {
			ImageColor3 = Color3.fromRGB(255, 255, 255)
		},
		TopbarTitle = {
			TextColor3 = Color3.fromRGB(253, 158, 247)
		},

		Sidebar = {
			BackgroundColor3 = Color3.fromRGB(17,18,19),
			BackgroundTransparency = 0,
		},
		ContentContainer = {
			BackgroundColor3 = Color3.fromRGB(17,18,19),
			BackgroundTransparency = 0,
		},  

		Box = {
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			BackgroundTransparency = 0,
			TextColor3 = Color3.fromRGB(200, 200, 200),
			TextTransparency = 0.1,
		},

		Element = {
			BackgroundColor3 = Color3.fromRGB(22,23,24),
			BackgroundTransparency = 0,
		},
		ElementStroke = {
			Color = Color3.fromRGB(25, 26, 27),
			Transparency = 0,
		},

		InputBox = {
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			TextColor3 = Color3.fromRGB(200, 200, 200),
			PlaceholderColor3 = Color3.fromRGB(178, 178, 178),
		},

		DropdownChoice = {
			SelectedBackgroundColor3 = Color3.fromRGB(50, 50, 50),
			SelectedTextColor3 = Color3.fromRGB(235, 235, 235),
			SelectedBackgroundTransparency = 0,
			SelectedTextTransparency = 0,

			DeselectedBackgroundColor3 = Color3.fromRGB(50, 50, 50),
			DeselectedTextColor3 = Color3.fromRGB(235, 235, 235),
			DeselectedBackgroundTransparency = 1,
			DeselectedTextTransparency = 0,
		},

		SliderThumb = {
			ImageColor3 = Color3.fromRGB(253, 158, 247),
			ImageTransparency = 0,
			BackgroundTransparency = 1,
		},
		SliderBar = {
			BackgroundColor3 = Color3.fromRGB(38, 39, 40),
			BackgroundTransparency = 0,
		},
		SliderBarFill = {
			BackgroundColor3 = Color3.fromRGB(127, 79, 124),
			BackgroundTransparency = 0,
		},

		ToggleStroke = {
			EnabledColor = Color3.fromRGB(253, 158, 247),
			DisabledColor = Color3.fromRGB(235, 235, 235),
			Transparency = 0.25,
		},
		ToggleThumb = {
			EnabledColor = Color3.fromRGB(253, 158, 247),
			DisabledColor = Color3.fromRGB(235, 235, 235),
		},

		Line = {
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(25, 26, 27),
		},

		Tab = {
			BackgroundColor3 = Color3.fromRGB(22,23,24),
			SelectedBackgroundTransparency = 0,
			DeselectedBackgroundTransparency = 1,
		},
		TabStroke = {
			Color = Color3.fromRGB(25, 26, 27),
		},
		TabIcon = {
			SelectedImageColor3 = Color3.fromRGB(253, 158, 247),
			DeselectedImageColor3 = Color3.fromRGB(200, 200, 200),
		},
		TabLabel = {
			SelectedTextColor3 = Color3.fromRGB(253, 158, 247),
			DeselectedTextColor3 = Color3.fromRGB(200, 200, 200),
		},
	},
	Light = {
		Primary = {TextColor3 = Color3.fromRGB(36, 35, 35),},
		Secondary = {TextColor3 = Color3.fromRGB(121, 119, 118),},

		WindowShadow = {
			ImageColor3 = Color3.fromRGB(0, 0, 0),
			ImageTransparency = 0.7,
		},
		WindowStroke = {
			Color = Color3.fromRGB(255, 255, 255),
			Thickness = 1.2,
			Transparency = 0.95,
		},

		Topbar = {
			BackgroundColor3 = Color3.fromRGB(246, 241, 240),
			BackgroundTransparency = 0,
		},
		TopbarIcon = {
			ImageColor3 = Color3.fromRGB(36, 35, 35)
		},
		TopbarTitle = {
			TextColor3 = Color3.fromRGB(253, 158, 247)
		},

		Sidebar = {
			BackgroundColor3 = Color3.fromRGB(246, 241, 240),
			BackgroundTransparency = 0,
		},
		ContentContainer = {
			BackgroundColor3 = Color3.fromRGB(246, 241, 240),
			BackgroundTransparency = 0,
		},  

		Box = {
			BackgroundColor3 = Color3.fromRGB(230, 225, 224),
			BackgroundTransparency = 0,
			TextColor3 = Color3.fromRGB(121, 119, 118),
		},

		Element = {
			BackgroundColor3 = Color3.fromRGB(242, 237, 236),
			BackgroundTransparency = 0,
		},
		ElementStroke = {
			Color = Color3.fromRGB(229, 224, 223),
			Transparency = 0,
		},

		InputBox = {
			BackgroundColor3 = Color3.fromRGB(230, 225, 224),
			TextColor3 = Color3.fromRGB(121, 119, 118),
			PlaceholderColor3 = Color3.fromRGB(70, 70, 70),
		},

		DropdownChoice = {
			SelectedBackgroundColor3 = Color3.fromRGB(230, 225, 224),
			SelectedTextColor3 = Color3.fromRGB(121, 119, 118),
			SelectedBackgroundTransparency = 0,
			SelectedTextTransparency = 0,

			DeselectedBackgroundColor3 = Color3.fromRGB(230, 225, 224),
			DeselectedTextColor3 = Color3.fromRGB(121, 119, 118),
			DeselectedBackgroundTransparency = 1,
			DeselectedTextTransparency = 0,
		},

		SliderThumb = {
			ImageColor3 = Color3.fromRGB(253, 158, 247),
			ImageTransparency = 0,
			BackgroundTransparency = 1,
		},
		SliderBar = {
			BackgroundColor3 = Color3.fromRGB(200, 200, 200),
			BackgroundTransparency = 0,
		},
		SliderBarFill = {
			BackgroundColor3 = Color3.fromRGB(127, 79, 124),
			BackgroundTransparency = 0,
		},

		ToggleStroke = {
			EnabledColor = Color3.fromRGB(253, 158, 247),
			DisabledColor = Color3.fromRGB(229, 224, 223),
			Transparency = 0.25,
		},
		ToggleThumb = {
			EnabledColor = Color3.fromRGB(253, 158, 247),
			DisabledColor = Color3.fromRGB(229, 224, 223),
		},

		Line = {
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(200, 200, 200),
		},

		Tab = {
			BackgroundColor3 = Color3.fromRGB(242, 237, 236),
			SelectedBackgroundTransparency = 0,
			DeselectedBackgroundTransparency = 1,
		},
		TabStroke = {
			Color = Color3.fromRGB(229, 224, 223),
		},
		TabIcon = {
			SelectedImageColor3 = Color3.fromRGB(253, 158, 247),
			DeselectedImageColor3 = Color3.fromRGB(200, 200, 200),
		},
		TabLabel = {
			SelectedTextColor3 = Color3.fromRGB(253, 158, 247),
			DeselectedTextColor3 = Color3.fromRGB(36, 35, 35),
		},
	},
}

registry = {
	windows = {},

	motions = reg_motions,
} :: any

-- REALLY SHIT STUDIO SUPPORT FOR FILESYSTEM FUNCTIONS

local listfiles = listfiles :: (string) -> { string }
local isfolder = isfolder :: (string) -> boolean
local makefolder = makefolder :: (string) -> ()
local writefile = writefile :: (string, string) -> ()
local readfile = readfile :: (string) -> string?
local isfile = isfile :: (string) -> boolean

if RunService:IsStudio() then
	local WORKSPACE = Instance.new("Folder")
	WORKSPACE.Name = "workspace"
	WORKSPACE.Parent = workspace

	isfile = function(path: string): boolean
		local split = string.split(path, "/")
		local file = WORKSPACE :: Instance
		for i = 1, #split do
			if not file then
				return false
			end
			file = (file :: any):FindFirstChild(split[i])
		end
		return file ~= nil and file:IsA("StringValue")
	end

	makefolder = function(path: string)
		local fldr = Instance.new("Folder")
		-- in folder
		local split = string.split(path, "/")
		local parent = WORKSPACE
		for i = 1, #split - 1 do
			if not parent then
				break
			end
			parent = (parent :: any):FindFirstChild(split[i])
		end
		assert(parent)
		fldr.Name = split[#split]
		fldr.Parent = parent
	end

	isfolder = function(path: string): boolean
		-- in folder
		local split = string.split(path, "/")
		local parent = WORKSPACE
		for i = 1, #split - 1 do
			if not parent then
				break
			end
			parent = (parent :: any):FindFirstChild(split[i])
		end
		assert(parent)

		local name = split[#split]
		local fldr = parent:FindFirstChild(name)
		return if fldr then fldr:IsA("Folder") else false
	end

	writefile = function(path: string, content: string)
		local file = Instance.new("StringValue")
		file.Value = content
		local split = string.split(path, "/")
		local parent = WORKSPACE
		for i = 1, #split - 1 do
			if not parent then
				break
			end
			parent = (parent :: any):FindFirstChild(split[i])
		end
		assert(parent)
		file.Name = split[#split]
		file.Parent = parent
	end

	readfile = function(path: string): string?
		local split = string.split(path, "/")
		local file = WORKSPACE :: Instance
		for i = 1, #split do
			if not file then
				break
			end
			file = (file :: any):FindFirstChild(split[i])
		end
		return if file and file:IsA("StringValue") then HttpService:JSONDecode(file.Value) else nil
	end

	listfiles = function(path: string): { string }
		local split = string.split(path, "/")
		local folder = WORKSPACE
		for i = 1, #split do
			if not folder then
				break
			end
			folder = (folder :: any):FindFirstChild(split[i])
		end

		local children = folder:GetChildren()
		local names = table.create(#children)
		for _, instance in children do
			table.insert(names, instance.Name)
		end
		return names
	end
end

local encode_config, decode_config
do
	local function string_to_hex(s: string): string
		local len = #s
		local hex = table.create(len)
		for i = 1, len do
			hex[i] = string.format("%02x", string.byte(s, i))
		end
		return table.concat(hex)
	end

	local function hex_to_string(hex: string): string
		local len = #hex
		local s = table.create(len // 2)
		for i = 1, len // 2 do
			local byte = tonumber(string.sub(hex, i * 2 - 1, i * 2), 16)
			if byte then
				s[i] = string.char(byte)
			end
		end
		return table.concat(s)
	end

	type ConfigDatatype<T> = {
		read: (buf: buffer, cursor: number) -> (T, number?),
		write: (buf: buffer, cursor: number, value: T) -> number?,
		len: number,
		type_id: number,
	}

	local buf
	local cursor = 0

	-- 🔧 safer realloc function
	local function realloc(size: number)
		local len = buffer.len(buf)
		local required = cursor + size
		if len < required then
			local new_len = math.ceil(required * 1.5)
			local new_buf = buffer.create(new_len)
			buffer.copy(new_buf, 0, buf, 0, len)
			buf = new_buf
		end
	end

	local DATATYPES = {
		number = {
			read = function(buf, cursor)
				return buffer.readf64(buf, cursor)
			end,
			write = function(buf, cursor, value)
				realloc(8)
				buffer.writef64(buf, cursor, value)
				return 8
			end,
			len = 8,
			type_id = 0,
		} :: ConfigDatatype<number>,

		Vector3 = {
			read = function(buf, cursor)
				local x = buffer.readf32(buf, cursor)
				local y = buffer.readf32(buf, cursor + 4)
				local z = buffer.readf32(buf, cursor + 8)
				return vector.create(x, y, z)
			end,
			write = function(buf, cursor, value)
				realloc(12)
				buffer.writef32(buf, cursor, value.x)
				buffer.writef32(buf, cursor + 4, value.y)
				buffer.writef32(buf, cursor + 8, value.z)
				return 12
			end,
			len = 12,
			type_id = 1,
		} :: ConfigDatatype<vector>,

		Color3 = {
			read = function(buf, cursor)
				local r = buffer.readu8(buf, cursor)
				local g = buffer.readu8(buf, cursor + 1)
				local b = buffer.readu8(buf, cursor + 2)
				return Color3.fromRGB(r, g, b)
			end,
			write = function(buf, cursor, value)
				realloc(3)
				local r = math.round(value.R * 255)
				local g = math.round(value.G * 255)
				local b = math.round(value.B * 255)
				buffer.writeu8(buf, cursor, r)
				buffer.writeu8(buf, cursor + 1, g)
				buffer.writeu8(buf, cursor + 2, b)
				return 3
			end,
			len = 3,
			type_id = 2,
		} :: ConfigDatatype<Color3>,

		boolean = {
			read = function(buf, cursor)
				return buffer.readu8(buf, cursor) == 1
			end,
			write = function(buf, cursor, value)
				realloc(1)
				buffer.writeu8(buf, cursor, value and 1 or 0)
				return 1
			end,
			len = 1,
			type_id = 3,
		} :: ConfigDatatype<boolean>,

		EnumItem = {
			read = function(buf, cursor)
				return Enum.KeyCode:FromValue(buffer.readu16(buf, cursor)) :: Enum.KeyCode
			end,
			write = function(buf, cursor, value)
				realloc(2)
				buffer.writeu16(buf, cursor, value.Value)
				return 2
			end,
			len = 2,
			type_id = 4,
		} :: ConfigDatatype<Enum.KeyCode>,

		string = {
			read = function(buf, cursor)
				local len = buffer.readu16(buf, cursor)
				local str = buffer.readstring(buf, cursor + 2, len)
				return str, len + 2
			end,
			write = function(buf, cursor, value)
				local len = #value
				realloc(len + 2)
				buffer.writeu16(buf, cursor, len)
				buffer.writestring(buf, cursor + 2, value)
				return len + 2
			end,
			len = 2, -- base len (excluding actual content)
			type_id = 5,
		} :: ConfigDatatype<string>,
	}

	local DATATYPES_TYPE_ID_MAP: { [number]: ConfigDatatype<any> } = {}
	for _, datatype in (DATATYPES :: any) :: { [string]: ConfigDatatype<any> } do
		DATATYPES_TYPE_ID_MAP[datatype.type_id] = datatype
	end

	-- 🔍 decode
	decode_config = function(content: string): { [string]: any }
		buf = buffer.fromstring(hex_to_string(content))
		cursor = 0
		local len = buffer.len(buf)

		local flags: { [string]: any } = {}

		while len > cursor do
			local name_len = buffer.readu16(buf, cursor)
			local name = buffer.readstring(buf, cursor + 2, name_len)
			cursor += 2 + name_len

			local type_id = buffer.readu8(buf, cursor)
			cursor += 1
			local datatype = DATATYPES_TYPE_ID_MAP[type_id]
			assert(datatype, `Invalid type id {type_id}`)

			local value, offset = datatype.read(buf, cursor)
			cursor += offset or datatype.len
			flags[name] = value
		end

		return flags
	end

	-- 💾 encode
	encode_config = function(flags: { [string]: Element }): string
		-- start with safe initial buffer, will grow dynamically
		buf = buffer.create(128)
		cursor = 0

		for name, element in flags do
			local value_src = element.Value
			if not value_src then
				continue
			end

			local value = value_src:get()
			local type = typeof(value)
			local datatype = DATATYPES[type]
			if not datatype then
				continue
			end

			local name_len = #name
			local estimated_len = 2 + name_len + datatype.len + 1
			if type == "string" then
				estimated_len = estimated_len + #value
			end
			realloc(estimated_len)

			-- write name
			buffer.writeu16(buf, cursor, name_len)
			buffer.writestring(buf, cursor + 2, name)
			cursor += 2 + name_len

			-- write type id
			buffer.writeu8(buf, cursor, datatype.type_id)
			cursor += 1

			-- write value
			local offset = datatype.write(buf, cursor, value) or datatype.len
			cursor += offset
		end

		-- trim buffer
		local exact_buf = buffer.create(cursor)
		buffer.copy(exact_buf, 0, buf, 0, cursor)
		return string_to_hex(buffer.tostring(exact_buf))
	end
end

local active_window: Window?

local function apply_theme_to_instance(window: Window, instance: Instance, theme_tag: ThemeTag)
	local theme = window.theme
	local properties = window.themes[theme][theme_tag]
	if not properties then
		return
	end

	for property, value in properties do
		pcall(function()
			(instance :: any)[property] = value
		end)
	end
end

local function get_themed_property(window: Window, theme_tag: ThemeTag, property: Property)
	local theme = window.theme
	local properties = window.themes[theme][theme_tag] or DEFAULT_THEMES.Dark[theme_tag]
	return properties[property] or DEFAULT_THEMES.Dark[theme_tag][property]
end

local function window_apply_theme(window: Window)
	local theme = window.theme
	local tagged_properties = window.themes[theme]
	local theme_instances = window.theme_instances

	for tag, instances in theme_instances do
		local properties = tagged_properties[tag]
		if not properties then
			continue
		end

		for _, instance in instances do
			for property, value in properties do
				pcall(function()
					(instance :: any)[property] = value
				end)
			end
		end
	end
end

local springs = {
	super_soft = { tension = 60, friction = 22 },
	soft = { tension = 120, friction = 22 },
	soft_bounce = { tension = 160, friction = 14 },
	meow_bounce = { tension = 175, friction = 13 },
	snap_bounce = { tension = 220, friction = 10 },
	pop = {
		tension = 300,
		friction = 15,
		mass = 0.75,
		restingVelocity = 0.01,
	},
	fast_soft = {
		tension = 210,
		friction = 24,
	},
}

local function source<V>(value: V): Source<V>
	local listeners = {}
	local current_value = value

	local function source_listen(self, callback: (V) -> ()): () -> ()
		local idx = #listeners + 1
		listeners[idx] = callback
		task.spawn(callback, current_value)

		-- disconnector
		return function()
			listeners[idx] = nil
		end
	end

	local function fire_listeners()
		for _, callback in listeners do
			task.spawn(callback, current_value)
		end
	end

	local function source_get(self)
		return current_value
	end

	local function source_set(self, value)
		current_value = value
		fire_listeners()
	end

	return {
		kind = "source",

		get = source_get,
		set = source_set,
		listen = source_listen,
		fire_listeners = fire_listeners,
	}
end

local function clamped_motion(motion: Motion<number>, min: number, max: number): Source<number>
	local value = source(math.clamp(motion:get(), min, max))

	motion:onStep(function(value2)
		value:set(math.clamp(value2, min, max))
	end)

	return value
end

local function computed<A, B>(src: Source<A>, fn: (A) -> B): Source<B>
	local result = source(fn(src:get()))
	src:listen(function(value)
		result:set(fn(value))
	end)
	return result
end

local function motion<T>(initial_value: T): Motion<T>
	local motion = ripple.create_motion(initial_value) :: Motion<T>
	table.insert(registry.motions, motion)

	local window = active_window
	if window then
		table.insert(window.cleanups, function()
			local idx = table.find(registry.motions, motion)
			if idx then
				table.remove(registry.motions, idx)
			end
			motion:destroy()
		end)
	end

	if not registry.motion_connection then
		AWAKEN_MOTION()
	end
	return motion
end

local function create(name: string): ({ [any]: any }) -> Instance
	return function(properties)
		local instance = Instance.new(name)
		local theme_tag, themed_window

		for property, value in properties do
			if property == "theme_tag" then
				local window = active_window
				if window then
					local theme_instances = window.theme_instances
					local tagged = theme_instances[value]
					if not tagged then
						theme_instances[value] = { instance }
					else
						table.insert(tagged, instance)
					end

					themed_window = window
					theme_tag = value
				end
			elseif typeof(value) == "Instance" then
				value.Parent = instance
			elseif type(value) == "table" then
				if value.onStep and value.get then
					-- ripple motion
					(instance :: any)[property] = value:get()
					value:onStep(function(value)
						(instance :: any)[property] = value
					end)
				elseif value.kind == "source" then
					-- source
					(instance :: any)[property] = value:get()
					local disconnect = value:listen(function(value)
						(instance :: any)[property] = value
					end)
					local window = active_window
					if window then
						table.insert(window.cleanups, disconnect)
					end
				end
			else
				local old = (instance :: any)[property]
				if typeof(old) == "RBXScriptSignal" then
					local connection = (instance :: any)[property]:Connect(value)
					local window = active_window
					if window then
						table.insert(window.cleanups, function()
							connection:Disconnect()
						end)
					end
				else
					(instance :: any)[property] = value
				end
			end
		end

		-- apply theme tag
		if themed_window and theme_tag then
			apply_theme_to_instance(themed_window, instance, theme_tag)
		end

		return instance
	end
end

local function REGISTER_FONT(id: string)
	return {
		regular = Font.new(id),
		medium = Font.new(id, Enum.FontWeight.Medium),
		semibold = Font.new(id, Enum.FontWeight.SemiBold),
		bold = Font.new(id, Enum.FontWeight.Bold),
	}
end

local fonts = {
	builder_sans = REGISTER_FONT "rbxassetid://12187365364", -- ACTUALLY INTER
	--builder_sans = REGISTER_FONT "rbxassetid://16658221428",
	-- inter = REGISTER_FONT "rbxassetid://12187365364",
}

local fontSizes = {
	title = 14,
	subtitle = 13,
	body = 12,
	small = 11,
}

local function NEXT_ORDER<Props>(section: Section, props: Props & { Order: number? }): number
	local order = props.Order
	if order then
		return order
	end

	local new_order = section.content_order
	section.content_order += 1
	return new_order
end

local function ELEMENT_FLAG<Props>(element: Element, section: Section, props: Props & { Flag: string?, Title: string })
	local flags = section.tab.window.Flags
	local flag_name = props.Flag or props.Title
	local existing_flag = flags[flag_name]
	assert(not existing_flag, `a flag with the name {flag_name} already exists`)

	flags[flag_name] = element
end

local ENSURE_IMAGE

local GLOBAL_GUI
local function ensure_gui(): ScreenGui
	if GLOBAL_GUI then
		return GLOBAL_GUI
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "Library_container"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	if gethui then
		gui.Parent = gethui()
	else
		if RunService:IsStudio() then
			gui.Parent = Players.LocalPlayer.PlayerGui
		else
			if protect_gui then
				protect_gui(gui)
			end
			gui.Parent = game:GetService("CoreGui")
		end
	end

	GLOBAL_GUI = gui
	return gui
end

local NOTIFICATION_CONTAINER
local function ensure_notification_container(): Frame
	if NOTIFICATION_CONTAINER then
		return NOTIFICATION_CONTAINER
	end

	local container = create "Frame" {
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -20, 0, 20),
		Size = UDim2.new(0, 200, 1, 0),

		create "UIListLayout" {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		},
	} :: Frame
	container.Parent = ensure_gui()

	NOTIFICATION_CONTAINER = container
	return container
end

local function notification_new(window: Window, props: NotificationProps): Notification
	active_window = window
	local idx = #window.notifications + 1

	local duration = props.Duration or 5
	local bg_transparency = motion(1)
	local stroke_transparency = motion(1)
	local clamped_stroke_transparency = clamped_motion(stroke_transparency, 0, 1)
	local title_text_transparency = motion(1)
	local content_text_transparency = motion(1)
	local position = motion(UDim2.fromScale(1, 0))

	local closed = false

	local function close_springs()
		bg_transparency:spring(1, springs.soft)
		stroke_transparency:spring(1, springs.soft)
		title_text_transparency:spring(1, springs.soft)
		content_text_transparency:spring(1, springs.soft)
		position:spring(UDim2.fromScale(1, 0), springs.fast_soft)
	end

	local function update_springs()
		if closed then
			close_springs()
			return
		end

		bg_transparency:spring(get_themed_property(window, "ContentContainer", "BackgroundTransparency"), springs.soft)
		stroke_transparency:spring(get_themed_property(window, "WindowStroke", "Transparency"), springs.soft)
		title_text_transparency:spring(get_themed_property(window, "Primary", "TextTransparency") or 0, springs.soft)
		content_text_transparency:spring(get_themed_property(window, "Secondary", "TextTransparency") or 0, springs.soft)
		position:spring(UDim2.fromOffset(0, 0), springs.fast_soft)
	end

	local disconnect = window:theme_changed(update_springs)
	local function notification_destroy(self: Notification)
		closed = true
		task.cancel(self.thread)
		self.instance:Destroy()
		window.notifications[idx] = nil
		disconnect()
		title_text_transparency:destroy()
		bg_transparency:destroy()
		stroke_transparency:destroy()
		content_text_transparency:destroy()
	end

	local function notification_close(self: Notification)
		closed = true
		-- close
		close_springs()
		bg_transparency:onComplete(function()
			notification_destroy(self)
		end)
	end

	local wrapper = create "Frame" {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = idx,
	}

	local notification
	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(9, 10, 11),
		BackgroundTransparency = bg_transparency,
		Size = UDim2.fromScale(1, 0),
		Position = position,
		theme_tag = "ContentContainer",

		create "TextButton" {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			TextTransparency = 1,

			Activated = function()
				notification_close(notification)
			end,
		},

		create "TextLabel" {
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.bold,
			Size = UDim2.new(1, 0, 0, 15),
			Text = props.Title,
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.title,
			TextWrapped = true,
			TextTransparency = title_text_transparency,
			TextXAlignment = Enum.TextXAlignment.Left,
			theme_tag = "Primary",
		},

		create "TextLabel" {
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			LayoutOrder = 1,
			Position = UDim2.fromOffset(0, 16),
			Size = UDim2.fromScale(1, 0),
			Text = props.Text,
			TextColor3 = Color3.fromRGB(200, 200, 200),
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextTransparency = content_text_transparency,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			theme_tag = "Secondary"
		},

		create "UICorner" {
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 10),
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Thickness = 1.2,
			Transparency = clamped_stroke_transparency,
			theme_tag = "WindowStroke",
		},
	} :: Frame

	instance.Parent = wrapper
	wrapper.Parent = ensure_notification_container()

	local thread = task.delay(duration, function()
		notification_close(notification :: any)
	end)

	notification = {
		Destroy = notification_destroy,
		Close = notification_close,

		instance = instance,
		thread = thread,
	}

	-- open
	update_springs()

	window.notifications[idx] = notification
	active_window = nil
	return notification
end

local function dropdown_new(section: Section, props: DropdownProps): Dropdown
	local MAX_DROPDOWN_VISIBLE_ITEMS = 8

	local order = NEXT_ORDER(section, props)
	local tab = section.tab
	local window = tab.window
	active_window = window

	local title = props.Title

	local default_value = props.DefaultValue
	local callbacks: { (string | {string}) -> () } = if props.Callback then { props.Callback :: any } else {}
	local value = source(default_value :: string | {string})

	local dropdown_scroll: ScrollingFrame, scroll_list_layout: UIListLayout
	local item_cleanups: { () -> () }

	local visible = section.visible
	local items = props.Items

	local open = source(false)
	local search_text = source("")

	local function dropdown_set_items(self: Dropdown, items: { string })
		local function match_search(item: string, search: string): boolean
			local text = string.lower(search_text:get())
			return text == "" or text == string.rep(" ", #text) or string.sub(item, 1, #text) == text
		end

		local function button(item: string, order: number): TextButton
			local bg_color = motion(Color3.new())
			local bg_transparency = motion(1)
			local text_color = motion(Color3.new())
			local text_transparency = motion(1)

			local font = source(fonts.builder_sans.regular)

			local function spring_motions()
				local value = value:get() :: string | {string}
				local is_selected =
					if props.Multi then
					table.find(value :: {string}, item)
					else
					value == item

				font:set(if is_selected then fonts.builder_sans.medium else fonts.builder_sans.regular)

				if visible then
					-- open
					if is_selected then
						-- selected
						bg_color:spring(get_themed_property(window, "DropdownChoice", "SelectedBackgroundColor3"), springs.soft)
						bg_transparency:spring(get_themed_property(window, "DropdownChoice", "SelectedBackgroundTransparency"), springs.soft)
						text_color:spring(get_themed_property(window, "DropdownChoice", "SelectedTextColor3"), springs.soft)
						text_transparency:spring(get_themed_property(window, "DropdownChoice", "SelectedTextTransparency"), springs.soft)
					else
						-- unselected
						bg_color:spring(get_themed_property(window, "DropdownChoice", "DeselectedBackgroundColor3"), springs.soft)
						bg_transparency:spring(get_themed_property(window, "DropdownChoice", "DeselectedBackgroundTransparency"), springs.soft)
						text_color:spring(get_themed_property(window, "DropdownChoice", "DeselectedTextColor3"), springs.soft)
						text_transparency:spring(get_themed_property(window, "DropdownChoice", "DeselectedTextTransparency"), springs.soft)
					end
				else
					-- not visible
					bg_transparency:spring(1, springs.soft)
					text_transparency:spring(1, springs.soft)
				end
			end

			local disconnect1 = value:listen(spring_motions)
			local disconnect2 = open:listen(spring_motions)

			local item_visible = source(match_search(item, search_text:get()))

			local disconnect3 = search_text:listen(function(search)
				item_visible:set(match_search(item, search))
			end)
			window:theme_changed(spring_motions)

			table.insert(item_cleanups, function()
				disconnect1()
				disconnect2()
				disconnect3()
				bg_transparency:destroy()
				bg_color:destroy()
				text_transparency:destroy()
				text_color:destroy()
			end)

			return create "TextButton" {
				AutoButtonColor = false,
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = bg_transparency,
				BackgroundColor3 = bg_color,
				FontFace = font,
				Position = UDim2.fromScale(-0.0208333, 0.333333),
				Selectable = false,
				Size = UDim2.new(1, 0, 0, 13),
				Text = item,
				TextColor3 = text_color,
				TextSize = fontSizes.body,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = order,
				TextTransparency = text_transparency,
				theme_tag = "DropdownChoice",
				Visible = item_visible,

				Activated = function()
					local new_value: string | {string}
					if props.Multi then
						-- multi dropdown

						local new_items = table.clone(value:get() :: {string}) :: {string}
						local existing_idx = table.find(new_items, item)
						if existing_idx then
							-- remove if already in there
							table.remove(new_items, existing_idx)
						else
							-- add
							table.insert(new_items, item)
						end
						new_value = new_items
					else
						new_value = item
					end

					value:set(new_value)
					--open:set(false)
				end,

				create "UIPadding" {
					PaddingBottom = UDim.new(0, 4),
					PaddingLeft = UDim.new(0, 4),
					PaddingRight = UDim.new(0, 4),
					PaddingTop = UDim.new(0, 4),
				},

				create "UICorner" {
					CornerRadius = UDim.new(0, 4),
				},
			} :: TextButton
		end

		-- clear old
		if item_cleanups then
			for _, cleanup in item_cleanups do
				cleanup()
			end
		end

		for _, old_button in dropdown_scroll:GetChildren() do
			if old_button:IsA("TextButton") then
				old_button:Destroy()
			end
		end

		local item_count = #items
		item_cleanups = table.create(item_count)


		for order, item in items do
			button(item, order).Parent = dropdown_scroll
		end
	end

	local function dropdown_open(self: Dropdown)
		open:set(true)
	end

	local function dropdown_close(self: Dropdown)
		open:set(false)
	end

	local function dropdown_toggle(self: Dropdown)
		open:set(not open:get())
	end

	local dropdown = {
		kind = "dropdown" :: "dropdown",

		window = window,
		tab = tab,
		section = section,

		title = title,

		SetItems = dropdown_set_items,
		items = items,

		callbacks = callbacks,
		default_value = default_value,

		Value = value,

		Multi = props.Multi or false,

		Open = dropdown_open,
		Close = dropdown_close,
		Toggle = dropdown_toggle,
		IsOpen = false,
	}

	local function fire_listeners(value: string | {string})
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function dropdown_listen(self: Dropdown, callback: (string | {string}) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	dropdown.Listen = dropdown_listen

	local text
	if props.Multi then
		text = source(table.concat(value:get() :: {string}, ", "))
		value:listen(function(selected)
			text:set(table.concat(selected :: {string}, ", "))
		end)
	else
		text = value :: any
	end

	local button = create "TextButton" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(90, 19),
		Text = text,
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = section.content_transparency,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 5), --boxcorner
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},

		Activated = function()
			if tab.selected:get() then
				dropdown_open(dropdown :: any)
			end
		end,
	} :: TextButton

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			----theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = section.content_transparency,
			theme_tag = "Primary",

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			button,

			create "UIListLayout" {
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			theme_tag = "ElementStroke",
		},
	} :: Frame
	instance.Parent = section.container
	dropdown.instance = instance

	scroll_list_layout = create "UIListLayout" {
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	} :: UIListLayout

	local dropdown_size = motion(UDim2.fromScale(1, 0))
	local dropdown_transparency = motion(1)
	local dropdown_stroke_transparency = motion(1)

	dropdown_scroll = create "ScrollingFrame" {
		Active = true,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		Position = UDim2.fromOffset(0, 23),
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = dropdown_size,

		scroll_list_layout,

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 1),
			PaddingRight = UDim.new(0, 1),
			PaddingTop = UDim.new(0, 4),
		},
	} :: ScrollingFrame

	local search_box_transparency = motion(1)
	local search_box = create "TextBox" {
		Active = false,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		FontFace = fonts.builder_sans.regular,
		LayoutOrder = -1,
		PlaceholderText = "Search",
		Selectable = false,
		Size = UDim2.new(1, 0, 0, 21),
		Text = "",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextTransparency = search_box_transparency,
		TextXAlignment = Enum.TextXAlignment.Left,

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},
	} :: TextBox

	search_box:GetPropertyChangedSignal("Text"):Connect(function()
		search_text:set(search_box.Text)
	end)

	local divider_transparency = motion(1)
	local scroll_container = create "Frame" {
		Active = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(19, 20, 21),
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, 0),
		Selectable = true,
		SelectionGroup = true,
		BackgroundTransparency = dropdown_transparency,
		Size = UDim2.fromOffset(110, 0),
		theme_tag = "ContentContainer",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIStroke" {
			Color = Color3.fromRGB(15, 16, 17),
			Transparency = dropdown_stroke_transparency,
			theme_tag = "ElementStroke",
		},

		search_box,

		dropdown_scroll,


		create "Frame" {
			AnchorPoint = Vector2.new(0, 1),
			BackgroundColor3 = Color3.fromRGB(38, 39, 40),
			BorderSizePixel = 0,
			BackgroundTransparency = divider_transparency,
			Position = UDim2.fromOffset(0, 23),
			Size = UDim2.new(1, 0, 0, 1),
			theme_tag = "Line",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 2),
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 2),
			PaddingTop = UDim.new(0, 2),
		},
	} :: Frame
	scroll_container.Parent = ensure_gui()

	local function update_divider()
		if open:get() then
			divider_transparency:spring(get_themed_property(window, "Line", "BackgroundTransparency"), springs.fast_soft)
		else
			divider_transparency:spring(1, springs.fast_soft)
		end
	end
	window:theme_changed(update_divider)

	ELEMENT_FLAG(dropdown, section, props) -- register flag

	visible:listen(function(visible)
		if not visible then
			open:set(false)
		end
	end)

	value:listen(fire_listeners)

	dropdown_set_items(dropdown, items)

	local dropdown_target_size = UDim2.fromScale(1, 0)

	dropdown_size:onComplete(function(value)
		if value.Y.Offset == 0 then
			scroll_container.Visible = false
		end
	end)

	local function calculate_scroll_size()
		dropdown_target_size = UDim2.new(
			1,
			0,
			0,
			math.min(
				scroll_list_layout.AbsoluteContentSize.Y + 6,
				((MAX_DROPDOWN_VISIBLE_ITEMS - 1) * 1 + MAX_DROPDOWN_VISIBLE_ITEMS * 21) + 6
			)
		)
	end

	local function adjust_scroll_size()
		calculate_scroll_size()
		if open:get() then
			dropdown_size:spring(dropdown_target_size, springs.fast_soft)
		end
	end

	open:listen(function(open)
		dropdown.IsOpen = open
		if open then
			calculate_scroll_size()
			scroll_container.Interactable = true
			scroll_container.ZIndex = 2
			scroll_container.Visible = true

			dropdown_size:spring(dropdown_target_size, springs.fast_soft)
			dropdown_transparency:spring(get_themed_property(window, "ContentContainer", "BackgroundTransparency"), springs.soft)
			dropdown_stroke_transparency:spring(get_themed_property(window, "ElementStroke", "Transparency"), springs.soft)
			search_box_transparency:spring(0, springs.fast_soft)	
			divider_transparency:spring(get_themed_property(window, "Line", "BackgroundTransparency"), springs.fast_soft)
		else
			-- if dropdown is closing, make sure they cant still add text to the search box
			scroll_container.ZIndex = 1
			scroll_container.Interactable = false

			if search_box:IsFocused() then
				search_box:ReleaseFocus()
			end

			dropdown_size:spring(UDim2.fromScale(1, 0), springs.fast_soft)
			dropdown_transparency:spring(1, springs.soft)
			dropdown_stroke_transparency:spring(1, springs.soft)
			search_box_transparency:spring(1, springs.fast_soft)
			divider_transparency:spring(1, springs.fast_soft)
		end
	end)

	adjust_scroll_size()
	local con0 = scroll_list_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(adjust_scroll_size)

	local function update_scroll_position()
		local button_position = button.AbsolutePosition
		local position = UDim2.fromOffset(button_position.X, button_position.Y + GuiService.TopbarInset.Height) -- -21
		scroll_container.Position = position
	end

	update_scroll_position()
	local con1 = button:GetPropertyChangedSignal("AbsolutePosition"):Connect(update_scroll_position)
	local con2 = button:GetPropertyChangedSignal("AbsoluteSize"):Connect(update_scroll_position)

	local ClickInputs = {
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	};

	local con3 = UserInputService.InputEnded:Connect(function(input, _gpe)
		if _gpe then return end

		if not table.find(ClickInputs, input.UserInputType) then
			return;
		end
		
		if dropdown.IsOpen then
			dropdown:Close()
		end
	end)

	table.insert(window.cleanups, function()
		scroll_container:Destroy()
		con0:Disconnect()
		con1:Disconnect()
		con2:Disconnect()
		con3:Disconnect()
	end)

	table.insert(section.elements, dropdown)

	active_window = nil

	return dropdown
end

local function color_picker_new(section: Section, props: ColorPickerProps): ColorPicker
	local order = NEXT_ORDER(section, props)
	local tab = section.tab
	local window = tab.window
	active_window = window
	local title = props.Title

	local default_value = props.DefaultValue
	local callbacks: { (Color3) -> () } = if props.Callback then { props.Callback } else {}
	local value = source(default_value)

	local color_picker = {
		kind = "color_picker" :: "color_picker",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,
		default_value = default_value,

		Value = value,
	}

	local function fire_listeners(value: Color3)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function color_picker_listen(self: ColorPicker, callback: (Color3) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	color_picker.Listen = color_picker_listen

	local function focus_lost(text_box: TextBox, property: "R" | "G" | "B"): RBXScriptConnection
		local function reconstruct(value: number, current: Color3)
			if property == "R" then
				return Color3.new(value, current.G, current.B)
			elseif property == "G" then
				return Color3.new(current.R, value, current.B)
			else
				return Color3.new(current.R, current.G, value)
			end
		end

		return text_box.FocusLost:Connect(function(enter_pressed)
			if enter_pressed then
				local text = text_box.Text
				local new_value = tonumber(text)
				if not new_value then
					return
				end

				local current = value:get()
				value:set(reconstruct(new_value / 255, current))
			end
		end)
	end

	local hex_box = create "TextBox" {
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = 0.1,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromOffset(0, 116),
		Size = UDim2.fromOffset(60, 20),
		Text = "HEX",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},
	} :: TextBox
	hex_box.FocusLost:Connect(function(enter_pressed)
		if enter_pressed then
			local text = hex_box.Text
			local new_color = Color3.fromHex(text)
			if new_color then
				value:set(new_color)
			end
		end
	end)

	local box_r = create "TextBox" {
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = 0.1,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromOffset(0, 140),
		Size = UDim2.fromOffset(32, 20),
		Text = "255",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},
	} :: TextBox
	focus_lost(box_r, "R")

	local box_g = create "TextBox" {
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = 0.1,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromOffset(36, 140),
		Size = UDim2.fromOffset(32, 20),
		Text = "255",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},
	} :: TextBox
	focus_lost(box_g, "G")

	local box_b = create "TextBox" {
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = 0.1,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromOffset(72, 140),
		Size = UDim2.fromOffset(32, 20),
		Text = "255",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		},
	} :: TextBox
	focus_lost(box_b, "B")

	local move_connection: RBXScriptConnection?
	local color_container: CanvasGroup
	local hue_container: ImageLabel

	local color_picker_position = source(UDim2.fromScale(0, 0))
	local hue_picker_position = source(UDim2.fromScale(0, 0.5))
	local gradient_color = source(ColorSequence.new(Color3.new()))

	local last_hue, last_sat = value:get():ToHSV()

	value:listen(function(color)
		local h, s, v = color:ToHSV()

		-- preserve hue & sat
		if v == 0 then
			h = last_hue
			s = last_sat
		else
			last_hue = h
			last_sat = s
		end

		color_picker_position:set(UDim2.fromScale(s, 1 - v))
		hue_picker_position:set(UDim2.fromScale(h, 0.5))
		gradient_color:set(ColorSequence.new(
			Color3.new(1, 1, 1),
			Color3.fromHSV(h, 1, 1)
			))
	end)

	color_container = create "CanvasGroup" {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, 0, 0, 90),

		InputBegan = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if move_connection then
					move_connection:Disconnect()
				end

				move_connection = RunService.PreRender:Connect(function()
					local mouse_location = UserInputService:GetMouseLocation() - Vector2.yAxis * GuiService.TopbarInset.Height

					-- relative position (scale)
					local position = (mouse_location - color_container.AbsolutePosition) / color_container.AbsoluteSize

					--local old_h, old_s, old_v = value:get():ToHSV()

					--local h = value:get():ToHSV() -- keep old hue
					local h = last_hue
					local s = math.clamp(position.X, 0, 1)
					local v = math.clamp(1 - position.Y, 0, 1)

					last_sat = s

					local color = Color3.fromHSV(h, s, v)
					value:set(color)
				end)
			end
		end,

		InputEnded = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and move_connection then
				move_connection:Disconnect()
			end
		end,

		create "Frame" {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.new(),
			--Position = UDim2.fromScale(0.5, 0.5),
			Position = color_picker_position,
			Size = UDim2.fromOffset(5, 5),
			ZIndex = 2,

			create "UIStroke" {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Color3.new(1, 1, 1),
				Thickness = 1.5,
			},

			create "UICorner" {
				CornerRadius = UDim.new(0.5, 0),
			},
		},

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIGradient" {
			Color = gradient_color,
		},

		create "Frame" {
			BackgroundColor3 = Color3.new(),
			BorderColor3 = Color3.new(),
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),

			create "UIGradient" {
				Rotation = -90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			},
		},
	} :: CanvasGroup

	hue_container = create "Frame" {
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.new(0.5, 0, 0, 98),
		Size = UDim2.new(1, 0, 0, 7),

		InputBegan = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if move_connection then
					move_connection:Disconnect()
				end

				move_connection = RunService.PreRender:Connect(function()
					local mouse_location = UserInputService:GetMouseLocation() - Vector2.yAxis * GuiService.TopbarInset.Height

					-- relative position (scale)
					local position = (mouse_location - color_container.AbsolutePosition) / color_container.AbsoluteSize

					local hue = math.clamp(position.X, 0, 1)
					last_hue = hue

					local color = Color3.fromHSV(
						hue,
						select(2, value:get():ToHSV()) -- keep sat & val the same
					)

					value:set(color)
				end)
			end
		end,

		InputEnded = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and move_connection then
				move_connection:Disconnect()
			end
		end,

		create "Frame" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			--Position = UDim2.fromScale(0, 0.5),
			Position = hue_picker_position,
			Size = UDim2.fromOffset(7, 14),

			create "UICorner" {
				CornerRadius = UDim.new(1, 0),
			},
		},

		create "UICorner" {
			CornerRadius = UDim.new(1, 0),
		},

		create "UIGradient" {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
				ColorSequenceKeypoint.new(0.125, Color3.fromRGB(255, 165, 0)),
				ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 255, 0)),
				ColorSequenceKeypoint.new(0.375, Color3.fromRGB(0, 255, 0)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
				ColorSequenceKeypoint.new(0.625, Color3.fromRGB(0, 0, 255)),
				ColorSequenceKeypoint.new(0.75, Color3.fromRGB(128, 0, 128)),
				ColorSequenceKeypoint.new(0.875, Color3.fromRGB(255, 0, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
			}),
		},
	} :: ImageLabel

	local picker_frame = create "Frame" {
		Active = true,
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(9, 10, 11),
		ClipsDescendants = true,
		--Position = UDim2.fromScale(0.714769, 0.42234),
		Position = UDim2.fromScale(0, 0),
		Selectable = true,
		SelectionGroup = true,
		Size = UDim2.fromOffset(180, 165),
		Visible = false,
		theme_tag = "ContentContainer",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
		},

		create "UIStroke" {
			Color = Color3.fromRGB(15, 16, 17),
		},

		color_container,
		hue_container,

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 10),
		},

		hex_box,
		box_r,
		box_g,
		box_b,
	} :: Frame
	picker_frame.Parent = ensure_gui()

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = order,
		theme_tag = "Element",

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = section.content_transparency,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			theme_tag = "ElementStroke",
		},

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			create "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, 3),
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},

			create "TextButton" {
				Active = true,
				AutoButtonColor = false,
				AnchorPoint = Vector2.new(1, 0.5),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = value,
				BackgroundTransparency = section.content_transparency,
				LayoutOrder = 3,
				Position = UDim2.new(1, -116, 0.5, 0),
				Selectable = true,
				Size = UDim2.fromOffset(19, 19),
				TextTransparency = 1,

				Activated = function()
					local mouse_location = UserInputService:GetMouseLocation()
					picker_frame.Position = UDim2.fromOffset(mouse_location.X - 50, mouse_location.Y)
					picker_frame.Visible = not picker_frame.Visible
				end,

				create "UICorner" {
					CornerRadius = UDim.new(0, 4),
				},

				create "UIPadding" {
					PaddingLeft = UDim.new(0, 7),
					PaddingRight = UDim.new(0, 7),
				},
			},
		},
	} :: Frame
	instance.Parent = section.container
	color_picker.instance = instance

	local ClickInputs = {
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	};

	local con3 = UserInputService.InputEnded:Connect(function(input, _gpe)
		if _gpe then return end

		if not table.find(ClickInputs, input.UserInputType) then
			return;
		end
		
		if picker_frame.Visible then
			picker_frame.Visible = false
		end
	end)

	ELEMENT_FLAG(color_picker, section, props)

	local function to_value(rgb: number): number
		return math.round(rgb * 255)
	end

	value:listen(function(color)
		color = Color3.new(
			math.clamp(color.R, 0, 1),
			math.clamp(color.G, 0, 1),
			math.clamp(color.B, 0, 1)
		)
		fire_listeners(color)

		hex_box.Text = color:ToHex()
		box_r.Text = tostring(to_value(color.R))
		box_g.Text = tostring(to_value(color.G))
		box_b.Text = tostring(to_value(color.B))
	end)

	table.insert(section.elements, color_picker)
	active_window = nil
	return color_picker
end

local function range_slider_new(section: Section, props: RangeSliderProps): RangeSlider
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local min = props.Min
	local max = props.Max
	local title = props.Title

	local precision = props.Precision or 0.1
	local function apply_precision(value: number): number
		local factor = 1 / precision
		return math.round(value * factor) / factor
	end

	local props_default_value = props.DefaultValue
	local default_value =
		vector.create(apply_precision((props_default_value :: any).x), apply_precision((props_default_value :: any).y))

	local callbacks: { (vector) -> () } = if props.Callback then { props.Callback } else {}
	local value = source(default_value)

	local range_slider = {
		kind = "range_slider" :: "range_slider",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,
		default_value = default_value,

		min = min,
		max = max,

		Value = value,
	}

	local function fire_listeners(value: vector)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function range_slider_listen(self: RangeSlider, callback: (vector) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	range_slider.Listen = range_slider_listen

	local slider_size = motion(UDim2.fromOffset(0, 2))
	local slider_position = motion(UDim2.fromOffset(0, 0))

	local text_box_min = create "TextBox" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		PlaceholderColor3 = Color3.fromRGB(178, 178, 178),
		Position = UDim2.new(1, -116, 0.5, 0),
		Size = UDim2.fromOffset(20, 19),
		Text = tostring(default_value.x),
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = false,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 5), --boxcorner
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 7),
			PaddingRight = UDim.new(0, 7),
		},
	} :: TextBox

	local connection1 = text_box_min.FocusLost:Connect(function(enter_pressed)
		if enter_pressed then
			local text = text_box_min.Text
			local new_value = tonumber(text)
			if not new_value then
				return
			end

			local y = value:get().y
			local x = apply_precision(math.clamp(new_value, min, max))
			value:set(vector.create(x, y))
		end
	end)

	local text_box_max = create "TextBox" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		LayoutOrder = 1,
		PlaceholderColor3 = Color3.fromRGB(178, 178, 178),
		Position = UDim2.new(1, -116, 0.5, 0),
		Size = UDim2.fromOffset(20, 19),
		Text = tostring(default_value.y),
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = false,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 5), --boxcorner
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 7),
			PaddingRight = UDim.new(0, 7),
		},
	} :: TextBox

	local connection2 = text_box_max.FocusLost:Connect(function(enter_pressed)
		if enter_pressed then
			local text = text_box_max.Text
			local new_value = tonumber(text)
			if not new_value then
				return
			end

			local x = value:get().x
			local y = apply_precision(math.clamp(new_value, min, max))
			value:set(vector.create(x, y))
		end
	end)

	table.insert(window.cleanups, function()
		connection1:Disconnect()
		connection2:Disconnect()
	end)

	local start_hold, stop_hold

	local circle_x = create "ImageButton" {
		Active = false,
		AnchorPoint = Vector2.new(0, 0.5),
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Image = "rbxassetid://130553358180286",
		ImageColor3 = Color3.fromRGB(253, 158, 247),
		ImageTransparency = section.content_transparency,
		Position = UDim2.fromScale(0, 0.5),
		ScaleType = Enum.ScaleType.Fit,
		Selectable = false,
		Size = UDim2.fromOffset(9, 9),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		theme_tag = "SliderThumb",
		Interactable = false,
	} :: ImageButton

	local circle_y = create "ImageButton" {
		Active = false,
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Image = "rbxassetid://130553358180286",
		ImageColor3 = Color3.fromRGB(253, 158, 247),
		ImageTransparency = section.content_transparency,
		Position = UDim2.fromScale(1, 0.5),
		ScaleType = Enum.ScaleType.Fit,
		Selectable = false,
		Size = UDim2.fromOffset(9, 9),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		theme_tag = "SliderThumb",
		Interactable = false,
	} :: ImageButton

	local slider_bar = create "Frame" {
		Active = true,
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		LayoutOrder = 2,
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(110, 2),
		theme_tag = "SliderBar",

		create "UICorner" {
			CornerRadius = UDim.new(1, 0),
		},

		create "TextButton" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromScale(1, 5),
			Text = "",

			InputBegan = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					local mouse_location = UserInputService:GetMouseLocation()
					local abs_pos_x = circle_x.AbsolutePosition
					local abs_pos_y = circle_y.AbsolutePosition

					local dist_x = (mouse_location - abs_pos_x).Magnitude
					local dist_y = (mouse_location - abs_pos_y).Magnitude

					start_hold(dist_x < dist_y)
				end
			end,

			InputEnded = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					stop_hold()
				end
			end,
		},

		create "Frame" {
			Active = true,
			BackgroundColor3 = Color3.fromRGB(127, 79, 124),
			BackgroundTransparency = section.box_bg_transparency,
			Selectable = true,
			Position = slider_position,
			Size = slider_size,
			theme_tag = "SliderBarFill",

			create "UICorner" {
				CornerRadius = UDim.new(1, 0),
			},

			circle_x,
			circle_y,
		},
	} :: Frame

	local connection: RBXScriptConnection?
	stop_hold = function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	start_hold = function(is_min: boolean)
		stop_hold()
		local function update_value()
			local mouse_location = UserInputService:GetMouseLocation()
			local abs_pos = slider_bar.AbsolutePosition
			local abs_size = slider_bar.AbsoluteSize
			local rel_x = math.clamp(mouse_location.X - abs_pos.X, 0, abs_size.X)
			local percent = rel_x / abs_size.X

			local new_value = apply_precision(min + (max - min) * percent)

			local current_max = value:get().y
			local current_min = value:get().x

			if is_min then
				-- make sure min isnt above max
				if new_value > current_max then
					new_value = current_max
				end
				value:set(vector.create(new_value, current_max))
			else
				-- make sure max isnt below min
				if new_value < current_min then
					new_value = current_min
				end
				value:set(vector.create(current_min, new_value))
			end
		end

		update_value()
		connection = RunService.PreRender:Connect(update_value)
	end

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = section.content_transparency,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			theme_tag = "ElementStroke",
		},

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			text_box_min,

			text_box_max,

			slider_bar,

			create "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},
		},
	} :: Frame
	instance.Parent = section.container
	range_slider.instance = instance

	ELEMENT_FLAG(range_slider, section, props)

	value:listen(function(range)
		fire_listeners(range)

		local x, y = range.x, range.y

		text_box_min.Text = tostring(x)
		text_box_max.Text = tostring(y)

		local ratio_min = (x - min) / (max - min)
		local ratio_max = (y - min) / (max - min)

		local bar_start = math.min(ratio_min, ratio_max)
		local bar_end = math.max(ratio_min, ratio_max)
		local bar_width = bar_end - bar_start

		slider_position:spring(UDim2.fromScale(bar_start, 0), springs.fast_soft)
		slider_size:spring(UDim2.new(bar_width, 0, 0, 2), springs.fast_soft)
	end)

	table.insert(section.elements, range_slider)

	active_window = nil
	return range_slider
end

local function keybind_new(section: Section, props: KeybindProps): Keybind
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local blacklisted_keys = props.BlacklistedKeys or {}
	local title = props.Title

	local default_value = props.DefaultValue
	local callbacks: { (Enum.KeyCode) -> () } = if props.Callback then { props.Callback } else {}

	local value = source(default_value)
	local keybind = {
		kind = "keybind" :: "keybind",

		window = window,
		tab = tab,
		section = section,

		title = title,

		blacklisted_keys = blacklisted_keys,

		callbacks = callbacks,
		default_value = default_value,

		Value = value,
	}

	local function fire_listeners(value: Enum.KeyCode)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function keybind_listen(self: Keybind, callback: (Enum.KeyCode) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	keybind.Listen = keybind_listen

	local function get_text_for_key(key: Enum.KeyCode)
		return UserInputService:GetStringForKeyCode(key) or key.Name
	end

	local connection: RBXScriptConnection?
	local take_input

	local button = create "TextButton" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(20, 19),
		Text = get_text_for_key(default_value),
		TextTransparency = section.content_transparency,
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = false,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 5), --boxcorner
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 7),
			PaddingRight = UDim.new(0, 7),
		},

		Activated = function()
			take_input()
		end,

	} :: TextButton

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextTransparency = section.content_transparency,
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			create "UIListLayout" {
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			button,
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			theme_tag = "ElementStroke",
		},
	} :: Frame
	instance.Parent = section.container
	keybind.instance = instance

	take_input = function()
		if connection then
			connection:Disconnect()
		end

		button.Text = "..."
		connection = UserInputService.InputBegan:Connect(function(input, gpe)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				value:set(input.KeyCode)
				if connection then
					connection:Disconnect()
				end
			end
		end)
	end

	ELEMENT_FLAG(keybind, section, props)

	value:listen(function(value)
		fire_listeners(value)
		button.Text = get_text_for_key(value)
	end)

	table.insert(section.elements, keybind)

	active_window = nil
	return keybind
end

local function slider_new(section: Section, props: SliderProps): Slider
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local min = props.Min
	local max = props.Max
	local title = props.Title

	local precision = props.Precision or 0.1
	local function apply_precision(value: number): number
		local factor = 1 / precision
		return math.round(value * factor) / factor
	end

	local default_value = apply_precision(math.clamp(props.DefaultValue, min, max))
	local callbacks: { (number) -> () } = if props.Callback then { props.Callback } else {}

	local value = source(default_value)
	local slider = {
		kind = "slider" :: "slider",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,
		default_value = default_value,

		min = min,
		max = max,

		Value = value,
	}

	local function fire_listeners(value: number)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function slider_listen(self: Slider, callback: (number) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	slider.Listen = slider_listen

	local start_hold, stop_hold

	local slider_thumb_ap = motion(Vector2.new(0, 0.5))
	local slider_size = motion(UDim2.fromOffset(0, 2))

	local slider_bar = create "Frame" {
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		LayoutOrder = 1,
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(110, 2),
		theme_tag = "SliderBar",

		create "Frame" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			ZIndex = 2,
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromScale(1, 5),

			InputBegan = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					start_hold()
				end
			end,

			InputEnded = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					stop_hold()
				end
			end,
		},

		create "UICorner" {
			CornerRadius = UDim.new(1, 0),
		},

		create "Frame" {
			Active = true,
			BackgroundColor3 = Color3.fromRGB(127, 79, 124),
			BackgroundTransparency = section.box_bg_transparency,
			Size = slider_size,
			theme_tag = "SliderBarFill",

			create "UICorner" {
				CornerRadius = UDim.new(1, 0),
			},

			create "ImageButton" {
				Active = false,
				AnchorPoint = slider_thumb_ap,
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Interactable = false,
				Image = "rbxassetid://130553358180286",
				ImageTransparency = section.content_transparency,
				ImageColor3 = Color3.fromRGB(253, 158, 247),
				Position = UDim2.fromScale(1, 0.5),
				ScaleType = Enum.ScaleType.Fit,
				Selectable = false,
				Size = UDim2.fromOffset(9, 9),
				SizeConstraint = Enum.SizeConstraint.RelativeYY,
				theme_tag = "SliderThumb",
			},
		},
	} :: Frame

	local text_box = create "TextBox" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		PlaceholderColor3 = Color3.fromRGB(178, 178, 178),
		Position = UDim2.new(1, -116, 0.5, 0),
		Size = UDim2.fromOffset(20, 19),
		Text = tostring(default_value),
		TextTransparency = section.content_transparency,
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		TextWrapped = false,
		theme_tag = "Box",

		create "UICorner" {
			CornerRadius = UDim.new(0, 5), --boxcorner
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 7),
			PaddingRight = UDim.new(0, 7),
		},
	} :: TextBox

	text_box.FocusLost:Connect(function(enter_pressed)
		if enter_pressed then
			local text = text_box.Text
			local new_value = tonumber(text)
			if not new_value then
				return
			end
			value:set(apply_precision(math.clamp(new_value, min, max)))
		end
	end)

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			slider_bar,

			create "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},

			text_box,
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextTransparency = section.content_transparency,
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			theme_tag = "ElementStroke",
		},
	} :: Frame
	instance.Parent = section.container
	slider.instance = instance

	local connection: RBXScriptConnection?
	stop_hold = function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	start_hold = function()
		stop_hold()
		local function update_value()
			local mouse_location = UserInputService:GetMouseLocation()
			local abs_pos = slider_bar.AbsolutePosition
			local abs_size = slider_bar.AbsoluteSize
			local relative_x = math.clamp(mouse_location.X - abs_pos.X, 0, abs_size.X)
			local percent = relative_x / abs_size.X
			local new_value = min + (max - min) * percent
			value:set(apply_precision(new_value))
		end

		update_value()
		connection = RunService.PreRender:Connect(update_value)
	end

	ELEMENT_FLAG(slider, section, props)

	value:listen(function(value)
		fire_listeners(value)

		text_box.Text = tostring(value)

		local ratio = (value - min) / (max - min)
		slider_size:spring(UDim2.new(ratio, 0, 0, 2), springs.fast_soft)
		slider_thumb_ap:spring(Vector2.new(ratio, 0.5), springs.fast_soft)
	end)

	table.insert(section.elements, slider)

	active_window = nil
	return slider
end

local function divider_new(section: Section, props: DividerProps): Divider
	local order = if props then props.Order else nil
	if not order then
		order = section.content_order
		section.content_order += 1
	end

	local tab = section.tab
	local window = tab.window
	active_window = window

	local divider = {
		kind = "divider" :: "divider",

		window = window,
		tab = tab,
		section = section,
	}

	local transparency = motion(1)
	section.visible:listen(function(visible)
		if visible then
			transparency:spring(get_themed_property(window, "Line", "BackgroundTransparency"), springs.soft)
		else
			transparency:spring(1, springs.soft)
		end
	end)

	local instance = create "Frame" {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.new(1, 0, 0, 7),

		create "Frame" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			-- BackgroundTransparency = 0.1,
			BackgroundTransparency = transparency,
			BorderColor3 = Color3.new(),
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, 0, 0, 1),
			theme_tag = "Line",
		},
	} :: Frame
	instance.Parent = section.container
	divider.instance = instance

	active_window = nil
	return divider
end

local function toggle_new(section: Section, props: ToggleProps): Toggle
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local title = props.Title
	local default_value = props.DefaultValue
	local callbacks: { (boolean) -> () } = if props.Callback then { props.Callback } else {}
	local value = source(default_value)

	local toggle = {
		kind = "toggle" :: "toggle",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,
		default_value = default_value,

		Value = value,
	}

	local accent_toggle_thumb = motion(Color3.fromRGB(235, 235, 235))
	local accent_toggle_stroke = motion(Color3.fromRGB(235, 235, 235))
	local toggle_position = motion(UDim2.fromScale(0, 0.5))
	local toggle_anchor_point = motion(Vector2.new(0, 0.5))
	local stroke_transparency = motion(1)

	section.visible:listen(function(visible)
		if visible then
			local value = get_themed_property(window, "ToggleStroke", "Transparency") :: number
			stroke_transparency:spring(value, springs.soft)
		else
			stroke_transparency:spring(1, springs.soft)
		end
	end)

	local function fire_listeners(value: boolean)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function toggle_listen(self: Toggle, callback: (boolean) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	toggle.Listen = toggle_listen

	local function update_toggle_colors()
		local enabled = value:get()
		local color_name = if enabled then "EnabledColor" else "DisabledColor"
		accent_toggle_thumb:spring(get_themed_property(window, "ToggleThumb", color_name) :: Color3, springs.soft)
		accent_toggle_stroke:spring(get_themed_property(window, "ToggleStroke", color_name) :: Color3, springs.soft)
	end

	window:theme_changed(update_toggle_colors)

	ELEMENT_FLAG(toggle :: Toggle, section, props)

	value:listen(function(value)
		fire_listeners(value)

		update_toggle_colors()
		if value then
			toggle_position:spring(UDim2.fromScale(1, 0.5), springs.fast_soft)
			toggle_anchor_point:spring(Vector2.new(1, 0.5), springs.fast_soft)
		else
			toggle_position:spring(UDim2.fromScale(0, 0.5), springs.fast_soft)
			toggle_anchor_point:spring(Vector2.new(0, 0.5), springs.fast_soft)
		end
	end)

	local instance = create "TextButton" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = order,
		Text = "",
		TextTransparency = 1,
		theme_tag = "Element",

		Activated = function()
			value:set(not value:get())
		end,

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,
			Size = UDim2.fromOffset(0, 19),

			create "Frame" {
				Active = true,
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(1, 0.5),
				Selectable = true,
				Size = UDim2.fromOffset(30, 15),

				create "UICorner" {
					CornerRadius = UDim.new(1, 0),
				},

				create "ImageButton" {
					Active = false,
					AnchorPoint = toggle_anchor_point,
					AutoButtonColor = false,
					BackgroundTransparency = 1,
					Image = "rbxassetid://130553358180286",
					Interactable = false,
					ImageColor3 = accent_toggle_thumb,
					Position = toggle_position,
					ImageTransparency = section.content_transparency,
					ScaleType = Enum.ScaleType.Fit,
					Selectable = false,
					Size = UDim2.fromScale(1, 1),
					SizeConstraint = Enum.SizeConstraint.RelativeYY,
					theme_tag = "ToggleThumb",
				},

				create "UIStroke" {
					Color = accent_toggle_stroke,
					Transparency = stroke_transparency,
					theme_tag = "ToggleStroke",
				},

				create "UIPadding" {
					PaddingBottom = UDim.new(0, 2),
					PaddingLeft = UDim.new(0, 2),
					PaddingRight = UDim.new(0, 2),
					PaddingTop = UDim.new(0, 2),
				},
			},

			create "UIListLayout" {
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextTransparency = section.content_transparency,
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			theme_tag = "ElementStroke",
		},
	} :: TextButton
	instance.Parent = section.container
	toggle.instance = instance

	table.insert(section.elements, toggle)

	active_window = nil
	return toggle
end

--ToggleProps Toggle
local function button_new(section: Section, props: ButtonProps): Button
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local title = props.Title
	local callbacks: { () -> () } = if props.Callback then { props.Callback } else {}

	local button = {
		kind = "button" :: "button",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,
	}

	local function fire_listeners()
		for _, callback in callbacks do
			task.spawn(callback)
		end
	end

	local function button_listen(self: Button, callback: () -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	button.Listen = button_listen

	local instance = create "TextButton" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = section.element_bg_transparency,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = order,
		Text = "",
		TextTransparency = 1,
		theme_tag = "Element",

		Activated = function()
			fire_listeners()
		end,

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,
			Size = UDim2.fromOffset(0, 19),

			create "TextLabel" {
				Active = true,
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				FontFace = fonts.builder_sans.regular,
				Selectable = true,
				Size = UDim2.fromScale(0, 0),
				Text = "button",
				theme_tag = "Secondary",
				TextColor3 = Color3.fromRGB(200, 200, 200),
				TextTransparency = section.content_transparency,
				TextSize = fontSizes.small,
				TextWrapped = false,
				TextXAlignment = Enum.TextXAlignment.Right,
			},

			create "UIListLayout" {
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			},
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			theme_tag = "Primary",
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextTransparency = section.content_transparency,
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIStroke" {
			Color = Color3.new(1, 1, 1),
			Transparency = section.element_stroke_transparency,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			theme_tag = "ElementStroke",
		},
	} :: TextButton
	instance.Parent = section.container
	button.instance = instance

	table.insert(section.elements, button)
	ELEMENT_FLAG(button, section, props)

	active_window = nil
	return button
end

local function info_box_new(section: Section, props: InfoBoxProps): InfoBox
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local title = props.Title
	local content = source(props.Content)
	
	local infobox = {
		kind = "infobox" :: "infobox",

		window = window,
		tab = tab,
		section = section,
		
		SetContent = function(_, newContent)
			content:set(newContent)
		end,

		title = title,
		content = content,
	}
	
	local gradient_offset = motion(Vector2.new(-0.12, 0))

	local instance = create "Frame" {
		Name = "title",
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(22, 23, 24),
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",
		
		MouseEnter = function()
			gradient_offset:spring(Vector2.new(0, 0), springs.soft)
		end,
		
		MouseLeave = function()
			gradient_offset:spring(Vector2.new(-0.12, 0), springs.soft)
		end,
		
		create "UICorner" {
			Name = "UICorner",
			CornerRadius = UDim.new(0, 6),
		},

		create "UIPadding" {
			Name = "UIPadding",
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 8),
		},

		create "TextLabel" {
			Name = "Title",
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.semibold,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			TextColor3 = Color3.fromRGB(253, 158, 247),
			TextSize = fontSizes.subtitle,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			theme_tag = "TopbarTitle",
		},

		create "UIStroke" {
			Name = "UIStroke",
			Color = Color3.new(1, 1, 1),

			create "UIGradient" {
				Name = "UIGradient",
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, get_themed_property(window, "TopbarTitle", "TextColor3")),
					ColorSequenceKeypoint.new(0.12, get_themed_property(window, "ElementStroke", "Color")),
					ColorSequenceKeypoint.new(1, get_themed_property(window, "ElementStroke", "Color")),
				}),
				Offset = gradient_offset,
			},
		},

		create "UIListLayout" {
			Name = "UIListLayout",
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},

		create "TextLabel" {
			Name = "Content",
			Active = false,
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Text = content,
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.body, --test
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			theme_tag = "Primary", 
		},
	} :: Frame
	instance.Parent = section.container
	infobox.instance = instance

	table.insert(section.elements, infobox)
	ELEMENT_FLAG(infobox, section, props)

	active_window = nil
	return infobox
end

local function input_new(section: Section, props: InputProps): Input
	local order = NEXT_ORDER(section, props)

	local tab = section.tab
	local window = tab.window
	active_window = window

	local title = props.Title
	local default_value = props.DefaultValue or ''
	local callbacks: { (string) -> () } = if props.Callback then { props.Callback } else {}
	local value = source(default_value)

	local input = {
		kind = "input" :: "input",

		window = window,
		tab = tab,
		section = section,

		title = title,

		callbacks = callbacks,

		Value = value,
	}

	local function fire_listeners(value: string)
		for _, callback in callbacks do
			task.spawn(callback, value)
		end
	end

	local function toggle_listen(self: Toggle, callback: (string) -> ()): () -> ()
		local idx = #callbacks + 1
		callbacks[idx] = callback
		return function()
			-- no table.remove because it would fuck other indices
			callbacks[idx] = nil
		end
	end
	input.Listen = toggle_listen

	ELEMENT_FLAG(input :: Input, section, props)

	value:listen(fire_listeners)

	local box = create "TextBox" {
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(50, 50, 50),
		BackgroundTransparency = section.box_bg_transparency,
		FontFace = fonts.builder_sans.regular,
		PlaceholderColor3 = Color3.fromRGB(178, 178, 178),
		PlaceholderText = props.PlaceholderText or '',
		Position = UDim2.new(1, -116, 0.5, 0),
		Size = UDim2.fromOffset(40, 19),
		Text = default_value or "",
		TextTransparency = section.content_transparency,
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextSize = fontSizes.body,
		theme_tag = "InputBox",

		create "UICorner" {
			CornerRadius = UDim.new(0, 4),
		},

		create "UIPadding" {
			PaddingLeft = UDim.new(0, 7),
			PaddingRight = UDim.new(0, 7),
		},
	} :: TextBox

	local connection = box.FocusLost:Connect(function()
		value:set(box.Text)
	end)

	table.insert(window.cleanups, function()
		connection:Disconnect()
	end)

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(19, 20, 21),
		BackgroundTransparency = section.element_bg_transparency,
		LayoutOrder = order,
		Selectable = true,
		Size = UDim2.fromScale(1, 0),
		theme_tag = "Element",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "ElementCorner",
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
		},

		create "TextLabel" {
			Active = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextTransparency = section.content_transparency,
			FontFace = fonts.builder_sans.regular,
			Selectable = true,
			Size = UDim2.fromScale(1, 0),
			Text = title,
			TextColor3 = Color3.fromRGB(235, 235, 235),
			TextSize = fontSizes.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			theme_tag = "Primary",

			create "UICorner" {
				CornerRadius = UDim.new(0, 3),
			},

			create "UIFlexItem" {
				FlexMode = Enum.UIFlexMode.Shrink,
			},
		},

		create "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "Frame" {
			Active = true,
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Position = UDim2.fromScale(1, 0.5),
			Selectable = true,

			create "UIListLayout" {
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			box,
		},

		create "UIStroke" {
			Color = Color3.fromRGB(15, 16, 17),
			Transparency = section.element_stroke_transparency,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			theme_tag = "ElementStroke",
		},
	} :: Frame
	instance.Parent = section.container
	input.instance = instance

	table.insert(section.elements, input)

	active_window = nil
	return input
end

local function section_new(tab: Tab, props: SectionProps): Section
	local title = props.Title
	local order = props.Order :: number
	if not order then
		order = tab.section_order
		tab.section_order += 1
	end

	local window = tab.window
	active_window = window

	local section = {
		Input = input_new,
		Button = button_new,
		InfoBox = info_box_new,
		Toggle = toggle_new,
		Divider = divider_new,
		Slider = slider_new,
		Keybind = keybind_new,
		RangeSlider = range_slider_new,
		ColorPicker = color_picker_new,
		Dropdown = dropdown_new,

		window = window,
		tab = tab,

		title = title,

		content_order = 0,
		elements = {},

		box_bg_transparency = motion(1),
		element_bg_transparency = motion(1),
		element_stroke_transparency = motion(1),
	}

	local content_transparency = tab.section_transparency
	section.content_transparency = content_transparency

	local content_position = motion(UDim2.fromOffset(0, 0))

	local visible = tab.selected
	section.visible = visible

	visible:listen(function(selected)
		if selected then
			content_position:set(UDim2.fromOffset(0, 30))
			content_position:spring(UDim2.fromOffset(0, 0), springs.soft_bounce)
			section.box_bg_transparency:spring(
				get_themed_property(window, "Box", "BackgroundTransparency") :: number,
				springs.soft
			)
			section.element_bg_transparency:spring(
				get_themed_property(window, "Element", "BackgroundTransparency") :: number,
				springs.soft
			)
			section.element_stroke_transparency:spring(
				get_themed_property(window, "ElementStroke", "Transparency") :: number,
				springs.soft
			)
		else
			section.box_bg_transparency:spring(1, springs.soft)
			section.element_bg_transparency:spring(1, springs.soft)
			section.element_stroke_transparency:spring(1, springs.soft)
		end
	end)

	local container = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.fromScale(1, 0),
		-- Visible = container_visible,

		create "UIListLayout" {
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	} :: Frame

	local instance = create "Frame" {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = order,

		create "Frame" {
			BackgroundTransparency = 1,

			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromScale(1, 0),
			Position = content_position,

			container,

			create "Frame" {
				BackgroundTransparency = 1,
				LayoutOrder = -1,
				Size = UDim2.new(1, 0, 0, 11),

				create "TextLabel" {
					BackgroundTransparency = 1,
					FontFace = fonts.builder_sans.bold,
					TextXAlignment = Enum.TextXAlignment.Left,
					LayoutOrder = 1,
					Size = UDim2.fromScale(1, 1),
					Text = string.upper(title),
					TextTransparency = content_transparency,
					TextColor3 = Color3.fromRGB(235, 235, 235),
					TextScaled = false,
					TextSize = fontSizes.small,
					theme_tag = "Primary",
				},
			},
		},
	} :: Frame

	instance.Parent = tab.content

	section.container = container
	section.instance = instance

	active_window = nil

	return section
end

local function tab_new(window: Window, props: TabProps): Tab
	local title = props.Title
	local icon = props.Icon
	local order = props.Order :: number
	if not order then
		order = window.tab_order
		window.tab_order += 1
	end

	active_window = window

	local tab = {
		Section = section_new,

		window = window,
		title = title,
		icon = icon,

		section_order = 0,
	}

	local selected = computed(window.selected_tab, function(selected_tab)
		return selected_tab == tab
	end)
	tab.selected = selected

	local content_visible = source(selected:get())

	local bg_transparency = motion(1)
	local stroke_transparency = motion(1)
	local clamped_stroke_transparency = clamped_motion(stroke_transparency, 0, 1)
	local label_color = motion(get_themed_property(window, "TabLabel", "DeselectedTextColor3"))
	local image_color = motion(get_themed_property(window, "TabIcon", "DeselectedImageColor3"))

	local function update_springs()
		if selected:get() then
			content_visible:set(true)
			bg_transparency:spring(get_themed_property(window, "Tab", "SelectedBackgroundTransparency") or 0, springs.soft)
			stroke_transparency:spring(get_themed_property(window, "TabStroke", "Transparency") or 0, springs.soft)

			image_color:spring(get_themed_property(window, "TabIcon", "SelectedImageColor3"), springs.soft)
			label_color:spring(get_themed_property(window, "TabLabel", "SelectedTextColor3"), springs.soft)
		else
			bg_transparency:spring(get_themed_property(window, "Tab", "DeselectedBackgroundTransparency") or 1, springs.fast_soft)
			stroke_transparency:spring(1, springs.fast_soft)

			image_color:spring(get_themed_property(window, "TabIcon", "DeselectedImageColor3"), springs.fast_soft)
			label_color:spring(get_themed_property(window, "TabLabel", "DeselectedTextColor3"), springs.fast_soft)
		end
	end

	selected:listen(update_springs)
	window:theme_changed(update_springs)

	local section_transparency = motion(1)
	selected:listen(function(selected)
		if selected then
			section_transparency:spring(0, springs.soft)
		else
			section_transparency:spring(1, springs.soft)
		end
	end)
	tab.section_transparency = section_transparency

	section_transparency:onComplete(function(value)
		if value == 1 then
			content_visible:set(false)
		end
	end)

	local instance = create "CanvasGroup" {
		BackgroundColor3 = Color3.new(),
		BackgroundTransparency = bg_transparency,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = order,
		theme_tag = "Tab",

		create "UICorner" {
			CornerRadius = UDim.new(0, 6),
			--theme_tag = "TabCorner",
		},

		create "UIStroke" {
			Color = Color3.new(15, 16, 17),
			Transparency = clamped_stroke_transparency,
			theme_tag = "TabStroke",
		},

		create "TextLabel" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			FontFace = fonts.builder_sans.semibold,
			LayoutOrder = 1,
			Position = UDim2.new(0, 27, 0.5, 0),
			Size = UDim2.new(1, 0, 0, 14),
			Text = title,
			TextColor3 = label_color,
			TextSize = fontSizes.subtitle,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			theme_tag = "TabLabel",
		},

		create "ImageLabel" {
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			Image = ENSURE_IMAGE(icon),
			ImageColor3 = image_color,
			Position = UDim2.new(0, 8, 0.5, 0),
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(15, 15),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			theme_tag = "TabIcon",
		},

		create "TextButton" {
			BackgroundTransparency = 1,
			TextTransparency = 1,
			Size = UDim2.fromScale(1, 1),

			Activated = function()
				window.selected_tab:set(tab :: any)
			end,
		},
	} :: CanvasGroup
	instance.Parent = window.sidebar

	local content = create "ScrollingFrame" {
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
		Visible = content_visible,

		create "UIListLayout" {
			ItemLineAlignment = Enum.ItemLineAlignment.Center,
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 1),
			PaddingLeft = UDim.new(0, 1),
			PaddingRight = UDim.new(0, 2),
			PaddingTop = UDim.new(0, 1),
		},
	} :: ScrollingFrame
	content.Parent = window.content_container

	tab.content = content
	tab.instance = instance

	local len = #window.tabs
	table.insert(window.tabs, tab)
	if len == 0 then
		window.selected_tab:set(tab)
	end

	active_window = nil

	return tab
end

local function window_new(self: Library, props: WindowProps): Window
	local position = motion(UDim2.fromScale(0.5, 0.5))
	local body_transparency = motion(1)
	local container_transparency = motion(1)
	local stroke_transparency = motion(1)
	local clamped_stroke_transparency = clamped_motion(stroke_transparency, 0, 1)

	local function window_minimize(self: Window)
		if self.Minimized then
			return
		end

		self.Minimized = true

		position:spring(self.window_position + UDim2.fromOffset(0, 30), springs.soft)
		body_transparency:spring(1, springs.fast_soft)
		container_transparency:spring(1, springs.fast_soft)
		stroke_transparency:spring(1, springs.fast_soft)

		for _, element in self.Flags do
			if element.kind == "dropdown" then
				element:Close()
			end
		end

		repeat task.wait() until body_transparency:isComplete()
		if body_transparency:get() == 1 then
			self.container.Visible = false
		end
	end

	local function window_maximize(self: Window)	
		if not self.Minimized then
			return
		end

		self.container.Visible = true

		position:spring(self.window_position - UDim2.fromOffset(0, 30), springs.meow_bounce)
		body_transparency:spring(0, springs.fast_soft)
		container_transparency:spring(get_themed_property(self, "WindowShadow", "ImageTransparency"), springs.fast_soft)
		stroke_transparency:spring(get_themed_property(self, "WindowStroke", "Transparency"), springs.fast_soft)

		self.Minimized = false
	end

	local function window_toggle_minimized(self: Window)
		if self.Minimized then
			self:Maximize()
		else
			self:Minimize()
		end
	end

	local function window_destroy(self: Window)
		for _, cleanup in self.cleanups do
			cleanup()
		end

		if self.OnClose then
			self.OnClose()
		end

		self.container:Destroy()
		table.clear(self)

		if GLOBAL_GUI then
			GLOBAL_GUI:Destroy()
		end
	end

	local dir = props.Folder or props.Title
	local config_directory = `{dir}/configs`
	local function ensure_folder(path: string)
		if not isfolder(path) then
			makefolder(path)
		end
	end

	ENSURE_IMAGE = function(image: string, name: string?): string
		ensure_folder(dir)
		if string.find(image, "http") then
			local imageDir = if name then `{dir}/{name}.png` else `{dir}/lovely.png`

			if not isfile(imageDir) then
				local httpRequest = http_request or request
				if not httpRequest then
					return
				end
				
				local response = httpRequest { Url = image, Method = "GET" }

				if response and response.Body then 
					writefile(imageDir, response.Body)
				end 
			end

			return getcustomasset and getcustomasset(imageDir)
		else
			return image
		end
	end

	export type Settings = {
		theme: string?,
		config: string?,
	}
	local DEFAULT_SETTINGS: Settings = {
		theme = "Dark",
		config = "default",
	}

	local settings_dir = `{dir}/settings.json`
	local function window_get_settings(): Settings
		ensure_folder(dir)
		local settings_content = isfile(settings_dir) and readfile(settings_dir)
		if not settings_content then
			writefile(settings_dir, HttpService:JSONEncode(DEFAULT_SETTINGS))
			return DEFAULT_SETTINGS
		end
		return HttpService:JSONDecode(settings_content) or DEFAULT_SETTINGS
	end

	local function window_set_settings(settings: Settings)
		ensure_folder(dir)
		writefile(settings_dir, HttpService:JSONEncode(settings))
	end

	local function window_save_config(self: Window, name: string?)
		if not name then
			return
		end

		ensure_folder(dir)
		ensure_folder(config_directory)

		local content = encode_config(self.Flags)
		writefile(`{config_directory}/{name}.config`, content)
		return content
	end

	local function window_create_config(self: Window, name: string, flags)
		if not name or not flags then
			return
		end

		ensure_folder(dir)
		ensure_folder(config_directory)
		writefile(`{config_directory}/{name}.config`, flags)
	end

	local function window_get_config(self: Window, name: string) -- name always inputted, it can be 'default' for some.
		ensure_folder(dir)
		ensure_folder(config_directory)

		if not isfile(`{config_directory}/{name}.config`) then
			return
		end

		local config = decode_config(readfile(`{config_directory}/{name}.config`))

		if not config then
			return
		end 

		return config
	end

	local function window_copy_config(self: Window, name: string)
		ensure_folder(dir)
		ensure_folder(config_directory)

		if not isfile(`{config_directory}/{name}.config`) then
			return
		end

		local config = readfile(`{config_directory}/{name}.config`)

		if not config then
			return
		end 

		return config
	end

	-- this function is automatically called after all elements are created inside the main script. new users will also have this executed (and they dont have any cfg files)
	local function window_load_config(self: Window, name: string?)
		if not name then
			return 
		end

		ensure_folder(dir)
		ensure_folder(config_directory)

		local content = isfile(`{config_directory}/{name}.config`) and readfile(`{config_directory}/{name}.config`)

		if not content then
			return
		end

		local flags = decode_config(content)
		for name, element in self.Flags do
			local value = flags[name]
			if value then
				element.Value:set(value)
			end
		end
	end

	local function window_get_configs(self: Window): { [string]: string }
		ensure_folder(dir)
		ensure_folder(config_directory)

		local files = listfiles(config_directory)
		local configs = {}
		for _, file_name in files do
			local content = readfile(file_name)
			if not content then
				continue
			end

			local config_name = string.match(file_name, "([^/\\]+)%.%w+$")
			if not config_name then 
				continue
			end

			configs[config_name] = content
		end
		return configs
	end

	local function window_init_config(self: Window) -- Load default config
		local config_name = window_get_settings().config or "default"

		local content = window_get_config(self, config_name)

		if not content then
			-- create default
			window_save_config(self, config_name)
		else
			-- load default
			window_load_config(self, config_name)
		end
	end

	local function ser_theme(theme: ThemeData)
		local ser = {}
		for tag, properties in theme do
			local valid_properties = {}
			for property, value in properties do
				valid_properties[property] = if typeof(value) == "Color3"
					then { math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255) }
					else value
			end
			ser[tag] = valid_properties
		end
		return HttpService:JSONEncode(ser)
	end

	local function des_theme(ser: string): ThemeData
		local theme = {}
		for tag, properties in HttpService:JSONDecode(ser) do
			local des_properties = {}
			for property, value in properties do
				des_properties[property] = if type(value) == "table"
					then Color3.fromRGB(value[1], value[2], value[3])
					else value
			end
			theme[tag] = des_properties
		end
		return theme
	end

	local themes_dir = `{dir}/themes`

	local function window_load_themes(window: Window): { [string]: ThemeData }
		ensure_folder(dir)
		ensure_folder(themes_dir)

		for theme_name, theme in DEFAULT_THEMES :: { [string]: ThemeData } do
			writefile(`{themes_dir}/{theme_name}.json`, ser_theme(theme))
		end

		for _, theme_file in listfiles(themes_dir) do
			local content = readfile(theme_file)

			if not content then
				continue
			end

			local theme_name = string.match(theme_file, "([^/\\]+)%.%w+$")
			if not theme_name then
				-- unable to get a valid theme name
				continue
			end 

			window.themes[theme_name] = des_theme(content)
		end

		return window.themes
	end

	local function window_get_theme(window: Window, theme_name: string): string
		ensure_folder(dir)
		ensure_folder(themes_dir)

		local theme_dir = `{themes_dir}/{theme_name}.json`
		return isfile(theme_dir) and readfile(theme_dir)
	end

	local function window_add_theme(window: Window, name: string, data: string)
		ensure_folder(dir)
		ensure_folder(themes_dir)

		writefile(`{themes_dir}/{name}.json`, data)
		window.themes[name] = data
	end

	local function window_get_themes(window: Window, name: string): { [string]: ThemeData }
		ensure_folder(dir)
		ensure_folder(themes_dir)

		window_load_themes(window)
		return window.themes
	end

	local theme_changed_listeners = {}
	local function theme_changed(window: Window, fn: () -> ()): () -> ()
		table.insert(theme_changed_listeners, fn)
		return function()
			table.remove(theme_changed_listeners, table.find(theme_changed_listeners, fn))
		end
	end

	local function window_load_theme(window: Window, theme: string)
		window.theme = theme
		window_apply_theme(window)
		for _, fn in theme_changed_listeners do
			task.spawn(fn)
		end
	end

	local title = props.Title
	local cleanups: { () -> () } = {}
	local window = {
		Tab = tab_new,

		Notify = notification_new,
		notifications = {},

		Minimize = window_minimize,
		Maximize = window_maximize,
		ToggleMinimized = window_toggle_minimized,
		Minimized = false,

		Destroy = window_destroy,

		InitConfig = window_init_config,
		SaveConfig = window_save_config,
		CreateConfig = window_create_config,
		GetConfig = window_get_config,
		CopyConfig = window_copy_config,
		LoadConfig = window_load_config,
		GetConfigs = window_get_configs,

		LoadTheme = window_load_theme,
		AddTheme = window_add_theme,
		GetTheme = window_get_theme,
		GetThemes = window_get_themes,
		LoadThemes = window_load_themes,

		GetSettings = window_get_settings,
		SetSettings = window_set_settings,

		Flags = {},

		window_position = UDim2.fromScale(0.5, 0.5),

		title = title,
		config_folder = props.Folder or `config-{title}`,

		tabs = {},
		selected_tab = source((nil :: any) :: Tab),

		tab_order = 0,

		cleanups = cleanups,

		theme_changed = theme_changed,
		theme_instances = {},
		themes = DEFAULT_THEMES,

		theme = DEFAULT_SETTINGS.theme,
	}
	active_window = window :: Window

	local minimize_key = props.MinimizeKey or DEFAULT_MINIMIZE_KEY
	local minimize_connection = UserInputService.InputBegan:Connect(function(input, gpe)
		if not gpe and input.KeyCode == minimize_key then
			window_toggle_minimized(window :: Window)
		end
	end)
	table.insert(cleanups, function()
		minimize_connection:Disconnect()
	end)

	local content_container = create "Frame" {
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Color3.fromRGB(9, 10, 11),
		BackgroundTransparency = 0,
		BorderColor3 = Color3.new(),
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -150, 1, 0),
		theme_tag = "ContentContainer",

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 6),
		},
	} :: Frame

	local sidebar = create "Frame" {
		BackgroundColor3 = Color3.fromRGB(9, 10, 11),
		BackgroundTransparency = 0,
		BorderColor3 = Color3.new(),
		BorderSizePixel = 0,
		Size = UDim2.new(0, 150, 1, 0),
		theme_tag = "Sidebar",

		create "UIListLayout" {
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},

		create "UIPadding" {
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 8),
		},
	} :: Frame

	local exit_bg_transparency = motion(1)
	local notification_transparency = motion(1)
	local notification_title_transparency = motion(1)
	local notification_content_transparency = motion(1)
	local box_bg_transparency = motion(1)
	local box_text_transparency = motion(1)
	local element_bg_transparency = motion(1)
	local element_text_transparency = motion(1)
	local exit_stroke_transparency = motion(1)
	local exit_dialogue_visible = source(false)

	exit_bg_transparency:onComplete(function(value)
		if value == 1 then
			exit_dialogue_visible:set(false)
		end
	end)

	local function update_springs()
		if exit_dialogue_visible:get() then
			-- visible
			exit_bg_transparency:spring(0.2, springs.soft)
			notification_transparency:spring(get_themed_property(window :: Window, "ContentContainer", "BackgroundTransparency"), springs.soft)
			notification_title_transparency:spring(get_themed_property(window :: Window, "Primary", "TextTransparnency") or 0, springs.soft)
			notification_content_transparency:spring(get_themed_property(window :: Window, "Secondary", "TextTransparnency") or 0, springs.soft)
			box_bg_transparency:spring(get_themed_property(window :: Window, "Box", "BackgroundTransparency"), springs.soft)
			box_text_transparency:spring(get_themed_property(window :: Window, "Box", "TextTransparency"), springs.soft)	
			element_bg_transparency:spring(get_themed_property(window :: Window, "Element", "BackgroundTransparency"), springs.soft)
			element_text_transparency:spring(get_themed_property(window :: Window, "Element", "TextTransparency") or 0, springs.soft)		
			exit_stroke_transparency:spring(get_themed_property(window :: Window, "WindowStroke", "Transparency"), springs.soft)	
		else
			exit_bg_transparency:spring(1, springs.soft)
			notification_transparency:spring(1, springs.soft)
			notification_title_transparency:spring(1, springs.soft)
			notification_content_transparency:spring(1, springs.soft)
			box_bg_transparency:spring(1, springs.soft)
			box_text_transparency:spring(1, springs.soft)	
			element_bg_transparency:spring(1, springs.soft)
			element_text_transparency:spring(1, springs.soft)
			exit_stroke_transparency:spring(1, springs.soft)	
		end
	end

	exit_dialogue_visible:listen(update_springs);
	(window :: Window):theme_changed(update_springs)

	local exit_dialogue = create "Frame" {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(3, 3, 3),
		BackgroundTransparency = exit_bg_transparency,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -30, 1, -30),
		Visible = exit_dialogue_visible,
		ZIndex = 2,

		create "UICorner" {
			CornerRadius = UDim.new(0, 12),
			--theme_tag = "WindowCorner"
		},

		create "Frame" {
			AnchorPoint = Vector2.new(0.5, 0.5),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Color3.fromRGB(9, 10, 11),
			BackgroundTransparency = notification_transparency,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(220, 0),
			theme_tag = "ContentContainer",

			create "TextLabel" {
				BackgroundTransparency = 1,
				FontFace = fonts.builder_sans.bold,
				Size = UDim2.new(1, 0, 0, 15),
				Text = "Close Window",
				TextColor3 = Color3.fromRGB(235, 235, 235),
				TextScaled = false,
				TextSize = fontSizes.title,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTransparency = notification_title_transparency,
				theme_tag = "Primary",
			},

			create "UICorner" {
			},

			create "TextLabel" {
				BackgroundTransparency = 1,
				FontFace = fonts.builder_sans.regular,
				LayoutOrder = 1,
				Position = UDim2.fromOffset(0, 17),
				Size = UDim2.new(1, 0, 0, 26),
				Text = "Are you sure you want to close the window? This action cannot be undone.",
				TextColor3 = Color3.fromRGB(200, 200, 200),
				TextScaled = false,
				TextWrapped = true,
				TextSize = fontSizes.body,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextTransparency = notification_content_transparency,
				theme_tag = "Secondary",
			},

			create "UIStroke" {
				Color = Color3.new(1, 1, 1),
				Transparency = exit_stroke_transparency,
			},

			create "UIPadding" {
				PaddingBottom = UDim.new(0, 10),
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 10),
				PaddingTop = UDim.new(0, 10),
			},

			create "Frame" {
				BackgroundTransparency = 1,
				LayoutOrder = 2,
				Position = UDim2.fromOffset(0, 49),
				Size = UDim2.new(1, 0, 0, 20),

				create "TextButton" {
					AutoButtonColor = false,
					BackgroundColor3 = Color3.fromRGB(50, 50, 50),
					BackgroundTransparency = box_bg_transparency,
					FontFace = fonts.builder_sans.semibold,
					Size = UDim2.new(0.5, -2, 1, 0),
					Text = "Close",
					TextColor3 = Color3.fromRGB(235, 235, 235),
					TextSize = fontSizes.body,
					TextWrapped = true,
					TextTransparency = box_text_transparency,
					theme_tag = "DialogueClose",

					Activated = function()
						window_destroy(window :: Window)
					end,

					create "UICorner" {
						CornerRadius = UDim.new(0, 5),
					},
				},

				create "TextButton" {
					AnchorPoint = Vector2.new(1, 0),
					AutoButtonColor = false,
					BackgroundColor3 = Color3.new(),
					BackgroundTransparency = 1,
					FontFace = fonts.builder_sans.semibold,
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.new(0.5, -2, 1, 0),
					Text = "Cancel",
					TextColor3 = Color3.fromRGB(200, 200, 200),
					TextSize = fontSizes.body,
					TextWrapped = true,
					TextTransparency = element_text_transparency,

					Activated = function() exit_dialogue_visible:set(false) end,

					create "UICorner" {
						CornerRadius = UDim.new(0, 5),
					},
				},
			},
		},
	} :: Frame

	local loading_transparency = motion(1)
	local loading_scale = motion(0.93)

	local loading = create "CanvasGroup" {
		Name = "Loading",
		GroupTransparency = loading_transparency,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,

		create "UIListLayout" {
			Name = "UIListLayout",
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},

		create "ImageLabel" {
			Name = "ImageLabel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Image = ENSURE_IMAGE(ICON_BLUR),
			ImageColor3 = Color3.fromRGB(254, 160, 248),
			ImageTransparency = 0.7,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(80, 80),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,

			create "ImageLabel" {
				Name = "ImageLabel",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Image = ENSURE_IMAGE(ICON),
				Position = UDim2.fromScale(0.5, 0.5),
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromOffset(60, 60),
				SizeConstraint = Enum.SizeConstraint.RelativeYY,
			},
		},

		create "UIScale" {
			Scale = loading_scale,
		}
	} :: CanvasGroup

	local close_transparency = motion(1)
	local clamped_close_transparency = clamped_motion(close_transparency, 0, 1)
	local minimize_transparency = motion(1)
	local clamped_minimize_transparency = clamped_motion(minimize_transparency, 0, 1)

	local function handle_state_change(obj: string, state: string)
		local transparency: Motion<number> = if obj == "minimize" then minimize_transparency else close_transparency 

		transparency:spring(if state == "hover" then 0 else 1, springs.fast_soft)
	end

	local size = UDim2.fromOffset(552, 416) -- 622 originally on x axis

	local drag_connection: RBXScriptConnection?
	local function stop_drag()
		if drag_connection then
			drag_connection:Disconnect()
			drag_connection = nil
		end
	end

	local container: ImageLabel
	local function start_drag()
		stop_drag()

		local container_pos = container.AbsolutePosition + container.AbsoluteSize / 2
		local drag_offset = UserInputService:GetMouseLocation() - container_pos - Vector2.new(0, GuiService.TopbarInset.Height)
		drag_connection = RunService.PreRender:Connect(function()
			local mouse_location = UserInputService:GetMouseLocation()

			-- apply drag offset to ensure that if the user is like
			-- dragging the topbar that the topbar will drag with their cursor
			local new_position = UDim2.fromOffset(mouse_location.X - drag_offset.X, mouse_location.Y - drag_offset.Y)

			window.window_position = new_position
			position:spring(new_position, springs.fast_soft)
		end)
	end

	container = create "ImageLabel" {
		-- shadow

		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Image = "rbxassetid://87218987217949",
		ImageColor3 = Color3.new(),
		ImageTransparency = container_transparency,
		Position = position,
		ScaleType = Enum.ScaleType.Slice,
		Size = size,
		SliceCenter = Rect.new(47, 47, 172, 179),
		ZIndex = 0,
		theme_tag = "WindowShadow",

		exit_dialogue,

		loading,

		-- container
		create "CanvasGroup" {
			AnchorPoint = Vector2.new(0.5, 0.5),
			GroupTransparency = body_transparency,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -30, 1, -30),

			create "UICorner" {
				CornerRadius = UDim.new(0, 12),
				--theme_tag = "WindowCorner"
			},

			create "UIListLayout" {
				Padding = UDim.new(0, 1),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			create "UIStroke" {
				Color = Color3.new(1, 1, 1),
				Thickness = 1.2,
				Transparency = clamped_stroke_transparency,
				theme_tag = "WindowStroke",
			},

			-- content
			create "Frame" {
				BackgroundTransparency = 1,
				LayoutOrder = 1,
				Position = UDim2.fromOffset(0, 34),
				Size = UDim2.fromScale(1, 1),

				create "UIListLayout" {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
				},

				create "UIFlexItem" {
					FlexMode = Enum.UIFlexMode.Shrink,
				},

				-- content
				content_container,

				-- sidebar
				sidebar,
			},

			-- topbar
			create "Frame" {
				BackgroundColor3 = Color3.fromRGB(9, 10, 11),
				BackgroundTransparency = 0,
				BorderColor3 = Color3.new(),
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 34),
				theme_tag = "Topbar",

				InputBegan = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						start_drag()
					end
				end,

				InputEnded = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						stop_drag()
					end
				end,

				create "TextLabel" {
					AnchorPoint = Vector2.new(0, 0.5),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,
					FontFace = fonts.builder_sans.bold,
					Position = UDim2.new(0, 34, 0.5, 0),
					Size = UDim2.fromOffset(0, 15),
					Text = title,
					TextSize = fontSizes.title,
					TextColor3 = Color3.fromRGB(235, 235, 235),
					TextScaled = false,
					TextXAlignment = Enum.TextXAlignment.Left,
					theme_tag = "TopbarTitle"
				},

				create "Frame" {
					BackgroundColor3 = Color3.fromRGB(50, 50, 50),
					BackgroundTransparency = 0.1,
					BorderColor3 = Color3.new(),
					BorderSizePixel = 0,
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 0, 0, 1),
					theme_tag = "Topbar",

					create "Frame" {
						AnchorPoint = Vector2.new(0.5, 0),
						BackgroundColor3 = Color3.fromRGB(50, 50, 50),
						BackgroundTransparency = 0.1,
						BorderColor3 = Color3.new(),
						BorderSizePixel = 0,
						Position = UDim2.fromScale(0.5, 0),
						Size = UDim2.new(1, -14, 0, 1),
						theme_tag = "Line",
					},
				},

				create "TextButton" {
					AnchorPoint = Vector2.new(1, 0.5),
					AutoButtonColor = false,
					BackgroundTransparency = clamped_close_transparency,
					BackgroundColor3 = Color3.fromRGB(19, 20, 21),
					Position = UDim2.new(1, -8, 0.5, 0),
					Size = UDim2.fromOffset(20, 20),
					Text = "",
					theme_tag = "Tab",

					create "UICorner" {
						Name = "UICorner",
						CornerRadius = UDim.new(0, 5),
					},

					create "ImageLabel" {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundTransparency = 1,
						Image = "rbxassetid://10747384394",
						ImageColor3 = Color3.fromRGB(235, 235, 235),
						Position = UDim2.fromScale(0.5, 0.5),
						ScaleType = Enum.ScaleType.Fit,
						Size = UDim2.fromOffset(15, 15),
						theme_tag = "TopbarIcon",
					},

					create "UIStroke" {
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = Color3.fromRGB(15, 16, 17),
						Transparency = clamped_close_transparency,
						theme_tag = "TabStroke"
					},

					MouseEnter = function()
						handle_state_change("close", "hover")
					end,
					MouseLeave = function()
						handle_state_change("close", "leave")
					end,

					Activated = function()
						exit_dialogue_visible:set(true)
					end,
				},

				-- minimize
				create "TextButton" {
					AnchorPoint = Vector2.new(1, 0.5),
					AutoButtonColor = false,
					BackgroundTransparency = clamped_minimize_transparency,
					Position = UDim2.new(1, -32, 0.5, 0),
					Size = UDim2.fromOffset(20, 20),
					Text = "",
					theme_tag = "Tab",

					create "UICorner" {
						CornerRadius = UDim.new(0, 5),
					},

					create "ImageLabel" {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundTransparency = 1,
						Image = "rbxassetid://10734896206",
						ImageColor3 = Color3.fromRGB(235, 235, 235),
						Position = UDim2.fromScale(0.5, 0.5),
						ScaleType = Enum.ScaleType.Fit,
						Size = UDim2.fromOffset(15, 15),
						theme_tag = "TopbarIcon",
					},

					create "UIStroke" {
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = Color3.fromRGB(15, 16, 17),
						Transparency = clamped_minimize_transparency,
						theme_tag = "TabStroke"
					},

					MouseEnter = function()
						handle_state_change("minimize", "hover")
					end,
					MouseLeave = function()
						handle_state_change("minimize", "leave")
					end,

					Activated = function()
						notification_new(window :: Window, {
							Title = "Minimized",
							Text = `To maximize the window, use {minimize_key.Name}`,
						})
						window_minimize(window :: Window)
					end,
				},

				create "ImageLabel" {
					AnchorPoint = Vector2.new(0, 0.5),
					BackgroundTransparency = 1,
					Image = ENSURE_IMAGE(ICON), -- real topbar icon
					Position = UDim2.new(0, 12, 0.5, 0),
					Size = UDim2.fromOffset(16, 16),
					ScaleType = Enum.ScaleType.Fit
				},
			},
		},
	} :: ImageLabel
	container.Parent = ensure_gui()

	window.sidebar = sidebar
	window.content_container = content_container
	window.container = container

	table.insert(registry.windows, window)
	active_window = nil

	ensure_folder(dir)
	ensure_folder(config_directory)

	local settings = window_get_settings()
	window_load_themes(window :: Window)

	local theme = settings.theme
	if theme then
		window_load_theme(window :: Window, theme)
	end

	loading_transparency:spring(0, springs.super_soft)
	loading_scale:spring(1, springs.soft)

	task.wait(1.8)

	body_transparency:spring(0, springs.fast_soft)
	container_transparency:spring(get_themed_property(window :: Window, "WindowShadow", "ImageTransparency"), springs.fast_soft)
	stroke_transparency:spring(get_themed_property(window :: Window, "WindowStroke", "Transparency"), springs.fast_soft)

	repeat task.wait() until body_transparency:isComplete()

	task.wait(0.4)
	loading:Destroy()

	return window
end

local Library: Library = {
	Registry = registry,

	Window = window_new,
}

return Library
