defmodule Puck.TestSupport.BamlClientMock do
  @moduledoc false

  def call(_function_name, _args, _opts), do: raise("stub in test")
  def stream(_function_name, _args, _callback, _opts), do: raise("stub in test")
end

defmodule Puck.TestSupport.BamlCollectorMock do
  @moduledoc false

  def new(_name), do: raise("stub in test")
  def usage(_collector), do: raise("stub in test")
  def last_function_log(_collector), do: raise("stub in test")
end
