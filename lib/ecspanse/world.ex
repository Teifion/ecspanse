defmodule Ecspanse.World do
  @moduledoc """
  The `Ecspanse.World` module is the main entry point for the Ecspanse framework.

  The world module is defined with the `use Ecspanse.World` macro.

  ## Configuration

  The following configuration options are available:

  - `:fps_limit` - optional - the maximum number of frames per second. Defaults to `:unlimited`.

  ## Special Resources

  The framework creates some special resources, such as `State`, by default.

  ## Examples

  ```elixir
  defmodule TestWorld1 do
    use Ecspanse.World, fps_limit: 60

    def setup(world) do
      world
      |> Ecspanse.World.add_system(TestSystem5)
      |> Ecspanse.World.add_frame_end_system(TestSystem3)
      |> Ecspanse.World.add_frame_start_system(TestSystem2)
      |> Ecspanse.World.add_startup_system(TestSystem1)
      |> Ecspanse.World.add_shutdown_system(TestSystem4)
    end
  end
  ```

  """
  require Ex2ms
  require Logger

  alias __MODULE__
  alias Ecspanse.Frame
  alias Ecspanse.System
  alias Ecspanse.Util

  @type t :: %__MODULE__{
          operations: operations(),
          system_set_options: map()
        }

  @type operation ::
          {:add_system, System.system_queue(), Ecspanse.System.t()}
          | {:add_system, :batch_systems, Ecspanse.System.t(), opts :: keyword()}
  @type operations :: list(operation())

  @type name :: atom() | {:global, term()} | {:via, module(), term()}
  @type supervisor :: pid() | atom() | {:global, term()} | {:via, module(), term()}

  defstruct operations: [], system_set_options: %{}

  @doc """
  The `setup/1` callback is called when the world is created and is the place to schedule the running systems in the world.

  ## Parameters

  - `world` - the current state of the world.

  ## Returns

  The updated state of the world.

  ## Example

  ```elixir
  defmodule MyWorld do
    use World

    @impl World
    def setup(world) do
      world
      |> World.add_system(MySystem)
      |> World.add_frame_end_system(MyFrameEndSystem)
      |> World.add_frame_start_system(MyFrameStartSystem)
      |> World.add_startup_system(MyStartupSystem)
      |> World.add_shutdown_system(MyShutdownSystem)
    end
  end
  ```
  """

  @callback setup(t()) :: t()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      @behaviour Ecspanse.World

      fps_limit = Keyword.get(opts, :fps_limit, :unlimited)

      if fps_limit && not (is_integer(fps_limit) || fps_limit == :unlimited) do
        raise ArgumentError,
              "If set, the option :fps_limit must be a non negative integer in the World module #{inspect(__MODULE__)}"
      end

      Module.register_attribute(__MODULE__, :fps_limit, accumulate: false)
      Module.put_attribute(__MODULE__, :fps_limit, fps_limit)
      Module.register_attribute(__MODULE__, :ecs_type, accumulate: false)
      Module.put_attribute(__MODULE__, :ecs_type, :world)

      @doc false
      def __fps_limit__ do
        @fps_limit
      end

      @doc false
      def __ecs_type__ do
        @ecs_type
      end
    end
  end

  @doc """

  Adds a system set to the world.

  A system set is a way to group systems together. The `opts` parameter is a keyword list of options that are applied on top of the system's options inside the set. System sets can also be nested.
  See the `add_system/3` function for more information about the options.

  The `add_system_set/3` function takes the world as an argument and returns the updated world. Inside the function, new systems can be added using the `add_system_*` functions.

  ## Parameters

  - `world` - the current state of the world.
  - `{module, function}` - the module and function that define the system set.
  - `opts` - optional - a keyword list of options to apply to the system set.

  ## Returns

  The updated state of the world.

  ## Example

  ```elixir
  defmodule MyWorld do
    use World

    @impl World
    def setup(world) do
      world
      |> World.add_system_set({MySystemSet, :setup}, [run_in_state: :my_state])
    end
  end

  defmodule MySystemSet do
    def setup(world) do
      world
      |> World.add_system(MySystem, [option: "value"])
      |> World.add_system_set({MyNestedSystemSet, :setup})
    end
  end

  defmodule MyNestedSystemSet do
    def setup(world) do
      world
      |> World.add_system(MyNestedSystem)
    end
  end
  ```

  """
  @spec add_system_set(t(), {module(), function :: atom}, opts :: keyword()) :: t()
  def add_system_set(world, {module, function}, opts \\ []) do
    # add the system set options to the world
    # the World system_set_options is a map with the key {module, function} for every system set
    world = %World{
      world
      | system_set_options: Map.put(world.system_set_options, {module, function}, opts)
    }

    world = apply(module, function, [world])

    # remove the system set options from the world
    %World{world | system_set_options: Map.delete(world.system_set_options, {module, function})}
  end

  @doc """
  Adds a startup system to the world.

  A startup system is run only once when the world is created. Startup systems do not take options.

  ## Parameters

  - `world` - the current state of the world.
  - `system_module` - the module that defines the startup system.

  ## Returns

  The updated state of the world.
  """
  @spec add_startup_system(t(), system_module :: module()) :: t()
  def add_startup_system(%World{operations: operations} = world, system_module) do
    system = %System{
      module: system_module,
      queue: :startup_systems,
      execution: :sync,
      run_conditions: []
    }

    %World{world | operations: [{:add_system, system} | operations]}
  end

  @doc """

  Adds a frame start system to the world.

  A frame start system is executed synchronously at the beginning of each frame.
  Sync systems are executed in the order they were added to the world.

  ## Parameters

  - `world` - the current state of the world.
  - `system_module` - the module that defines the frame start system.
  - `opts` - optional - a keyword list of options to apply to the system. See the `add_system/3` function for more information about the options.

  ## Returns

  The updated state of the world.
  """

  @spec add_frame_start_system(t(), system_module :: module(), opts :: keyword()) :: t()
  def add_frame_start_system(%World{operations: operations} = world, system_module, opts \\ []) do
    opts = merge_system_options(opts, world.system_set_options)

    if Keyword.get(opts, :run_after) do
      Logger.warning(
        "The :run_after option is ignored by sync running systems. Those will always run in the order they were added to the world."
      )
    end

    system =
      %System{module: system_module, queue: :frame_start_systems, execution: :sync}
      |> add_run_conditions(opts)

    %World{world | operations: [{:add_system, system} | operations]}
  end

  @doc """
  Adds an async system to the world, to be executed asynchronously each frame during the game loop.

  The `add_system/3` function takes the world as an argument and returns the updated world. Inside the function, a new system is created using the `System` struct and added to the world's operations list.

  ## Parameters

  - `world` - the current state of the world.
  - `system_module` - the module that defines the system.
  - `opts` - optional - a keyword list of options to apply to the system.

  ## Options

  - `:run_in_state` - a list of states in which the system should be run.
  - `:run_not_in_state` - a list of states in which the system should not be run.
  - `:run_if` - a tuple containing the module and function that define a condition for running the system. Eg. `[{Module, :function}]`
  - `:run_after` - a system or list of systems that must be run before this system.

  ## Returns

  The updated state of the world.

  ## Order of execution
  You can specify the order in which systems are run using the `run_after` option. This option takes a system or list of systems that must be run before this system.

  When using the `run_after: SystemModule1` or `run_after: [SystemModule1, SystemModule2]` option, the following rules apply:

  - The system(s) specified in `run_after` must already be added to the world. This prevents circular dependencies.
  - There is a deliberate choice to allow only the `run_after` option. While a `before` option would simplify some relations, it can also introduce circular dependencies.

  For example, consider the following systems:

  - System A
  - System B, which must be run before System A
  - System C, which must be run after System A and before System B

  """
  @spec add_system(t(), system_module :: module(), opts :: keyword()) ::
          t()
  def add_system(%World{operations: operations} = world, system_module, opts \\ []) do
    opts = merge_system_options(opts, world.system_set_options)

    after_system = Keyword.get(opts, :run_after)

    run_after =
      case after_system do
        nil -> []
        after_systems when is_list(after_systems) -> after_systems
        after_system when is_atom(after_system) -> [after_system]
      end

    system =
      %System{
        module: system_module,
        queue: :batch_systems,
        execution: :async,
        run_after: run_after
      }
      |> add_run_conditions(opts)

    %World{world | operations: [{:add_system, system} | operations]}
  end

  @doc """

  Adds a frame end system to the world.

  A frame end system is executed synchronously at the end of each frame.
  Sync systems are executed in the order they were added to the world.

  ## Parameters

  - `world` - the current state of the world.
  - `system_module` - the module that defines the frame start system.
  - `opts` - optional - a keyword list of options to apply to the system. See the `add_system/3` function for more information about the options.

  ## Returns

  The updated state of the world.

  """
  @spec add_frame_end_system(t(), system_module :: module(), opts :: keyword()) :: t()
  def add_frame_end_system(%World{operations: operations} = world, system_module, opts \\ []) do
    opts = merge_system_options(opts, world.system_set_options)

    if Keyword.get(opts, :run_after) do
      Logger.warning(
        "The :run_after option is ignored by sync running systems. Those will always run in the order they were added to the world."
      )
    end

    system =
      %System{module: system_module, queue: :frame_end_systems, execution: :sync}
      |> add_run_conditions(opts)

    %World{world | operations: [{:add_system, system} | operations]}
  end

  @doc """
  Run only once on World shutdown
  Does not take options

  Adds a shutdown system to the world.

  A shudtown system is run only once when the world is terminated. Shutdown systems do not take options.

  ## Parameters

  - `world` - the current state of the world.
  - `system_module` - the module that defines the startup system.

  ## Returns

  The updated state of the world.
  """
  @spec add_shutdown_system(t(), system_module :: module()) :: t()
  def add_shutdown_system(%World{operations: operations} = world, system_module) do
    system = %System{
      module: system_module,
      queue: :shutdown_systems,
      execution: :sync,
      run_conditions: []
    }

    %World{world | operations: [{:add_system, system} | operations]}
  end

  @doc """
  Utility function used for testing and development purposes.

  The `debug/0` function returns the internal state of the world, which can be useful for debugging systems scheduling and batching. This function is only available in the `:dev` and `:test` environments.

  ## Returns

  The internal state of the world.

  """
  @spec debug() :: World.State.t()
  def debug() do
    if Mix.env() in [:dev, :test] do
      GenServer.call(Ecspanse.World, :debug)
    else
      {:error, "debug is only available for dev and test"}
    end
  end

  #############################
  #    INTERNAL STATE         #
  #############################

  defmodule State do
    @moduledoc false
    # should not be present in the docs

    @opaque t :: %__MODULE__{
              id: binary(),
              status:
                :startup_systems
                | :frame_start_systems
                | :batch_systems
                | :frame_end_systems
                | :frame_ended,
              frame_timer: :running | :finished,
              world_name: Ecspanse.World.name(),
              world_pid: pid(),
              world_module: module(),
              supervisor: Ecspanse.World.supervisor(),
              system_run_conditions_map: map(),
              startup_systems: list(Ecspanse.System.t()),
              frame_start_systems: list(Ecspanse.System.t()),
              batch_systems: list(list(Ecspanse.System.t())),
              frame_end_systems: list(Ecspanse.System.t()),
              shutdown_systems: list(Ecspanse.System.t()),
              scheduled_systems: list(Ecspanse.System.t()),
              await_systems: list(reference()),
              system_modules: MapSet.t(module()),
              last_frame_monotonic_time: integer(),
              fps_limit: non_neg_integer(),
              delta: non_neg_integer(),
              frame_data: Frame.t(),
              test: boolean(),
              test_pid: pid()
            }

    @enforce_keys [
      :id,
      :world_name,
      :world_pid,
      :world_module,
      :supervisor,
      :last_frame_monotonic_time,
      :fps_limit,
      :delta
    ]

    defstruct id: nil,
              status: :startup_systems,
              frame_timer: :running,
              world_name: nil,
              world_pid: nil,
              world_module: nil,
              supervisor: nil,
              system_run_conditions_map: %{},
              startup_systems: [],
              frame_start_systems: [],
              batch_systems: [],
              frame_end_systems: [],
              shutdown_systems: [],
              scheduled_systems: [],
              await_systems: [],
              system_modules: MapSet.new(),
              last_frame_monotonic_time: nil,
              fps_limit: :unlimited,
              delta: 0,
              frame_data: %Frame{},
              test: false,
              test_pid: nil
  end

  ### SERVER ###

  use GenServer

  @spec child_spec(data :: map()) :: map()
  @doc false
  def child_spec(data) do
    %{
      id: data.id,
      start: {__MODULE__, :start_link, [data]},
      restart: :transient
    }
  end

  @doc false
  def start_link(data) do
    GenServer.start_link(__MODULE__, data, name: data.world_name)
  end

  @impl true
  def init(data) do
    # The main reason for using ETS tables are:
    # - keep under control the GenServer memory usage
    # - elimitate GenServer bottlenecks. Various Systems or Queries can read directly from the ETS tables.

    # This is the main ETS table that holds the components state as a list of Ecspanse.Component.component_key_value() tuples
    # All processes can read and write to this table. But writing should only be done through Commands.
    # The race condition is handled by the System Component locking.
    # Commands should validate that only Systems are writing to this table.
    components_state_ets_table =
      :ets.new(:ets_ecspanse_components_state, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])

    # This is the ETS table that holds the resources state as a list of Ecspanse.Resource.resource_key_value() tuples
    # All processes can read and write to this table.
    # But writing should only be done through Commands.
    # Commands should validate that only Systems are writing to this table.
    resources_state_ets_table =
      :ets.new(:ets_ecspanse_resources_state, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: false
      ])

    # This ETS table stores Events as a list of event structs wraped in a tuple {{MyEventModule, key :: any()}, %MyEvent{}}.
    # Every frame, the objects in this table are deleted.
    # Any process can read and write to this table.
    # But the logic responsible to write to this table should check the stored values are actually event structs.
    # Before being sent to the Systems, the events are sorted by their inserted_at timestamp, and group in batches.
    # The batches are determined by the unicity of the event {EventModule, key} per batch.

    events_ets_table =
      :ets.new(:ets_ecspanse_events, [
        :duplicate_bag,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Store the ETS tables in an Agent so they can be accessed independently from this GenServer
    Agent.start_link(
      fn ->
        %{
          components_state_ets_table: components_state_ets_table,
          resources_state_ets_table: resources_state_ets_table,
          events_ets_table: events_ets_table
        }
      end,
      name: :ecspanse_ets_tables
    )

    state = %State{
      id: data.id,
      world_name: data.world_name,
      world_pid: self(),
      world_module: data.world_module,
      supervisor: data.supervisor,
      last_frame_monotonic_time: Elixir.System.monotonic_time(:millisecond),
      delta: 0,
      fps_limit: data.world_module.__fps_limit__(),
      test: data.test,
      test_pid: data.test_pid
    }

    # Special system that creates the default resources
    create_default_resources_system =
      %System{
        module: Ecspanse.System.CreateDefaultResources,
        queue: :startup_systems,
        execution: :sync
      }
      |> add_run_conditions([])

    %World{operations: operations} = state.world_module.setup(%World{})
    operations = operations ++ [{:add_system, create_default_resources_system}]

    state = operations |> Enum.reverse() |> apply_operations(state)

    send(self(), {:run, data.events})

    {:ok, state}
  end

  @impl true
  def handle_call(:debug, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:shutdown, state) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:run, system_start_events}, state) do
    # startup_events passed as options in the Ecspanse.new/2 function
    event_batches = batch_events(system_start_events)

    state = %{
      state
      | scheduled_systems: state.startup_systems,
        frame_data: %Frame{event_batches: event_batches}
    }

    send(self(), :run_next_system)
    {:noreply, state}
  end

  def handle_info(:start_frame, state) do
    # Collect Memoize garbage
    Task.start(fn ->
      Memoize.garbage_collect()
    end)

    # use monotonic time
    # https://til.hashrocket.com/posts/k6kydebcau-precise-timings-with-monotonictime
    frame_monotonic_time = Elixir.System.monotonic_time(:millisecond)
    delta = frame_monotonic_time - state.last_frame_monotonic_time

    event_batches =
      Util.events_ets_table()
      |> :ets.tab2list()
      |> batch_events()

    # Frame limit
    # in order to finish a frame, two conditions must be met:
    # 1. the frame time must pass: eg 1000/60 milliseconds.
    # .  this sets the frame_timer: from :running to :finished
    # 2. all the frame systems must have finished running
    # .  this sets the status: to :frame_ended,
    # So, when state.frame_timer == :finished && state.status == :frame_ended, the frame is finished

    one_sec = 1000
    limit = if state.fps_limit == :unlimited, do: 0, else: one_sec / state.fps_limit

    # the systems run conditions are refreshed every frame
    # this is intentional behaviour for performance reasons
    # but also to avoid inconsistencies in the components
    state = refresh_system_run_conditions_map(state)

    state = %{
      state
      | status: :frame_start_systems,
        frame_timer: :running,
        scheduled_systems: state.frame_start_systems,
        last_frame_monotonic_time: frame_monotonic_time,
        delta: delta,
        frame_data: %Frame{
          delta: delta,
          event_batches: event_batches
        }
    }

    # Delete all events from the ETS table
    :ets.delete_all_objects(Util.events_ets_table())

    Process.send_after(self(), :finish_frame_timer, round(limit))
    send(self(), :run_next_system)

    # for worlds started with the `test: true` option
    if state.test do
      send(state.test_pid, {:next_frame, state})
    end

    {:noreply, state}
  end

  # finished running strartup systems (sync) and starting the loop
  def handle_info(
        :run_next_system,
        %State{scheduled_systems: [], status: :startup_systems} = state
      ) do
    send(self(), :start_frame)
    {:noreply, state}
  end

  # finished running systems at the beginning of the frame (sync) and scheduling the batch systems
  def handle_info(
        :run_next_system,
        %State{scheduled_systems: [], status: :frame_start_systems} = state
      ) do
    state = %{state | status: :batch_systems, scheduled_systems: state.batch_systems}

    send(self(), :run_next_system)
    {:noreply, state}
  end

  # finished running batch systems (async per batch) and scheduling the end of the frame systems
  def handle_info(:run_next_system, %State{scheduled_systems: [], status: :batch_systems} = state) do
    state = %{state | status: :frame_end_systems, scheduled_systems: state.frame_end_systems}

    send(self(), :run_next_system)
    {:noreply, state}
  end

  # finished running systems at the end of the frame (sync) and scheduling the end of frame
  def handle_info(
        :run_next_system,
        %State{scheduled_systems: [], status: :frame_end_systems} = state
      ) do
    send(self(), :end_frame)
    {:noreply, state}
  end

  # running batch (async) systems. This runs only for `batch_systems` status
  def handle_info(
        :run_next_system,
        %State{scheduled_systems: [systems_batch | batches], status: :batch_systems} = state
      ) do
    systems_batch = Enum.filter(systems_batch, &run_system?(&1, state.system_run_conditions_map))

    case systems_batch do
      [] ->
        state = %{state | scheduled_systems: batches, await_systems: []}
        send(self(), :run_next_system)
        {:noreply, state}

      systems_batch ->
        # Choosing this approach instead of using `Task.async_stream` because
        # we don't want to block the server while processing the batch
        # Also it re-uses the same code as the sync systems
        refs = Enum.map(systems_batch, &run_system(&1, state))

        state = %{state | scheduled_systems: batches, await_systems: refs}

        {:noreply, state}
    end
  end

  # running sync systems
  def handle_info(:run_next_system, %State{scheduled_systems: [system | systems]} = state) do
    if run_system?(system, state.system_run_conditions_map) do
      ref = run_system(system, state)
      state = %{state | scheduled_systems: systems, await_systems: [ref]}

      {:noreply, state}
    else
      state = %{state | scheduled_systems: systems, await_systems: []}
      send(self(), :run_next_system)
      {:noreply, state}
    end
  end

  # systems finished running and triggering next. The message is sent by the Task
  def handle_info({ref, :finished_system_execution}, %State{await_systems: [ref]} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state = %State{state | await_systems: []}

    send(self(), :run_next_system)
    {:noreply, state}
  end

  def handle_info(
        {ref, :finished_system_execution},
        %State{await_systems: system_refs} = state
      )
      when is_reference(ref) do
    unless ref in system_refs do
      raise "Received System message from unexpected System: #{inspect(ref)}"
    end

    Process.demonitor(ref, [:flush])
    state = %State{state | await_systems: List.delete(system_refs, ref)}
    {:noreply, state}
  end

  # finishing the frame systems and scheduling the next one
  def handle_info(:end_frame, state) do
    state = %State{state | status: :frame_ended}

    if state.frame_timer == :finished do
      send(self(), :start_frame)
    end

    {:noreply, state}
  end

  def handle_info(:finish_frame_timer, state) do
    state = %State{state | frame_timer: :finished}

    if state.status == :frame_ended do
      send(self(), :start_frame)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Running shutdown_systems. Those cannot run in the standard way because the process is shutting down.
    # They are executed sync, in the ordered they were added.
    Enum.each(state.shutdown_systems, fn system ->
      task =
        Task.async(fn ->
          prepare_system_process(system)
          system.module.run(state.frame_data)
        end)

      Task.await(task)
    end)
  end

  ### HELPER ###

  defp run_system(system, state) do
    %Task{ref: ref} =
      Task.async(fn ->
        prepare_system_process(system)
        system.module.schedule_run(state.frame_data)
        :finished_system_execution
      end)

    ref
  end

  # This happens in the System process
  defp prepare_system_process(system) do
    Process.put(:ecs_process_type, :system)
    Process.put(:system_execution, system.execution)
    Process.put(:system_module, system.module)
    Process.put(:locked_components, system.module.__locked_components__())
  end

  defp apply_operations([], state), do: state

  defp apply_operations([operation | operations], state) do
    %State{} = state = apply_operation(operation, state)
    apply_operations(operations, state)
  end

  # batch async systems
  defp apply_operation(
         {:add_system,
          %System{queue: :batch_systems, module: system_module, run_after: []} = system},
         state
       ) do
    state = validate_unique_system(system_module, state)

    batch_systems = Map.get(state, :batch_systems)

    # should return a list of lists
    new_batch_systems = batch_system(system, batch_systems, [])

    Map.put(state, :batch_systems, new_batch_systems)
    |> Map.put(
      :system_run_conditions_map,
      add_to_system_run_conditions_map(state.system_run_conditions_map, system)
    )
  end

  defp apply_operation(
         {:add_system,
          %System{queue: :batch_systems, module: system_module, run_after: after_systems} = system},
         state
       ) do
    state = validate_unique_system(system_module, state)
    batch_systems = Map.get(state, :batch_systems)

    system_modules = batch_systems |> List.flatten() |> Enum.map(& &1.module)

    non_exising_systems = after_systems -- system_modules

    if length(non_exising_systems) > 0 do
      raise "Systems #{inspect(non_exising_systems)} does not exist. A system can run only after existing systems"
    end

    # should return a list of lists
    new_batch_systems = batch_system_after(system, after_systems, batch_systems, [])

    Map.put(state, :batch_systems, new_batch_systems)
    |> Map.put(
      :system_run_conditions_map,
      add_to_system_run_conditions_map(state.system_run_conditions_map, system)
    )
  end

  # add sequential systems to their queues
  defp apply_operation(
         {:add_system, %System{queue: queue, module: system_module} = system},
         state
       ) do
    state = validate_unique_system(system_module, state)

    Map.put(state, queue, Map.get(state, queue) ++ [system])
    |> Map.put(
      :system_run_conditions_map,
      add_to_system_run_conditions_map(state.system_run_conditions_map, system)
    )
  end

  defp validate_unique_system(system_module, state) do
    Ecspanse.Util.validate_ecs_type(
      system_module,
      :system,
      ArgumentError,
      "The module #{inspect(system_module)} must be a System"
    )

    if MapSet.member?(state.system_modules, system_module) do
      raise "System #{inspect(system_module)} already exists. World systems must be unique."
    end

    %State{state | system_modules: MapSet.put(state.system_modules, system_module)}
  end

  defp batch_system(system, [], []) do
    [[system]]
  end

  defp batch_system(system, [], checked_batches) do
    checked_batches ++ [[system]]
  end

  defp batch_system(system, [batch | batches], checked_batches) do
    # when one or more locked components are entity specific {component, entity_type_component}
    # need to verify also that the generic component is not present as locked in the batch
    # this adds quite a bit of extra complexity
    # it needs to check also for new components not to be present in the batch as entity scoped components

    # Example
    # System1 lock_components [Component1]
    # and
    # System2 lock_components [{Component1, EntityTypeComponent}]
    # should NOT be allowed in the same batch

    system_locked_components = system.module.__locked_components__()

    entity_scoped_components =
      Enum.filter(system_locked_components, &match?({_, entity_type: _}, &1))
      |> Enum.map(&elem(&1, 0))

    batch_locked_components =
      Enum.map(batch, & &1.module.__locked_components__()) |> List.flatten()

    entity_scoped_batched =
      Enum.filter(batch_locked_components, &match?({_, entity_type: _}, &1))
      |> Enum.map(&elem(&1, 0))

    if batch_locked_components --
         system_locked_components --
         entity_scoped_components ==
         batch_locked_components and
         entity_scoped_batched --
           system_locked_components ==
           entity_scoped_batched do
      updated_batch = batch ++ [system]
      # return result
      checked_batches ++ [updated_batch] ++ batches
    else
      batch_system(system, batches, checked_batches ++ [batch])
    end
  end

  defp batch_system_after(system, [] = _after_systems, remaining_batches, checked_batches) do
    batch_system(system, remaining_batches, checked_batches)
  end

  defp batch_system_after(system, after_system_modules, [batch | batches], checked_batches) do
    remaining_after_systems = after_system_modules -- Enum.map(batch, & &1.module)

    batch_system_after(
      system,
      remaining_after_systems,
      batches,
      checked_batches ++ [batch]
    )
  end

  defp add_run_conditions(system, opts) do
    run_in_state =
      case Keyword.get(opts, :run_in_state, []) do
        state when is_atom(state) -> [state]
        states when is_list(states) -> states
      end

    run_in_state_functions =
      Enum.map(run_in_state, fn state ->
        {Ecspanse.Util, :run_system_in_state, [state]}
      end)

    run_not_in_state =
      case Keyword.get(opts, :run_not_in_state, []) do
        state when is_atom(state) -> [state]
        states when is_list(states) -> states
      end

    run_not_in_state_functions =
      Enum.map(run_not_in_state, fn state ->
        {Ecspanse.Util, :run_system_not_in_state, [state]}
      end)

    run_if =
      case Keyword.get(opts, :run_if, []) do
        {module, function} = condition when is_atom(module) and is_atom(function) -> [condition]
        conditions when is_list(conditions) -> conditions
      end

    run_if_functions =
      Enum.map(run_if, fn {module, function} ->
        {module, function, []}
      end)

    %System{
      system
      | run_conditions: run_in_state_functions ++ run_not_in_state_functions ++ run_if_functions
    }
  end

  # builds a map with all running conditions from all systems
  # this allows to run the conditions only per frame
  defp add_to_system_run_conditions_map(
         existing_conditions,
         %{run_conditions: run_conditions} = _system
       ) do
    run_conditions
    |> Enum.reduce(existing_conditions, fn condition, acc ->
      # Adding false as initial value for the condition
      # because this cannot run on startup systems
      # this will be updated in the refresh_system_run_conditions_map
      Map.put(acc, condition, false)
    end)
  end

  # takes state and returns state
  defp refresh_system_run_conditions_map(state) do
    state.system_run_conditions_map
    |> Enum.reduce(
      state,
      fn {{module, function, args} = condition, _value}, state ->
        result = apply(module, function, args)

        unless is_boolean(result) do
          raise "System run condition functions must return a boolean. Got: #{inspect(result)}. For #{inspect({module, function, args})}."
        end

        %State{
          state
          | system_run_conditions_map: Map.put(state.system_run_conditions_map, condition, result)
        }
      end
    )
  end

  defp run_system?(system, run_conditions_map) do
    Enum.all?(system.run_conditions, fn condition ->
      Map.get(run_conditions_map, condition) == true
    end)
  end

  # merge the system options with the system set options
  defp merge_system_options(system_opts, system_set_opts)
       when is_list(system_opts) and is_map(system_set_opts) do
    system_set_opts = Map.values(system_set_opts) |> List.flatten() |> Enum.uniq()

    (system_opts ++ system_set_opts)
    |> Enum.group_by(fn {k, _v} -> k end, fn {_k, v} -> v end)
    |> Enum.map(fn {k, v} -> {k, v |> List.flatten() |> Enum.uniq()} end)
  end

  defp batch_events(events) do
    # inserted_at is the System time in milliseconds when the event was created
    events
    |> Enum.sort_by(fn {_k, v} -> v.inserted_at end, &</2)
    |> do_event_batches([])
  end

  defp do_event_batches([], batches), do: batches

  defp do_event_batches(events, batches) do
    current_events = Enum.uniq_by(events, fn {k, _v} -> k end)

    batch =
      Enum.map(current_events, fn {_, v} -> v end)

    remaining_events = events -- current_events
    do_event_batches(remaining_events, batches ++ [batch])
  end
end
