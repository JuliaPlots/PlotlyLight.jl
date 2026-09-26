# Templates

Templates are set by using the `preset.template.<template>!` family of functions:

```@example templates
using PlotlyLight

keys(PlotlyLight.preset.template)
```

We'll use the following plot to demonstrate each template:

```@example templates
plt = plot.bar(y = randn(10))

nothing # hide
```

## `none!()`

```@example templates
preset.template.none!()
plt  # hide
```

## `ggplot2!()`

```@example templates
preset.template.ggplot2!()
plt  # hide
```

## `gridon!()`

```@example templates
preset.template.gridon!()
plt  # hide
```

## `plotly!()`

```@example templates
preset.template.plotly!()
plt  # hide
```

## `plotly_dark!()`

```@example templates
preset.template.plotly_dark!()
plt  # hide
```

## `plotly_white!()`

```@example templates
preset.template.plotly_white!()
plt  # hide
```

## `presentation!()`

```@example templates
preset.template.presentation!()
plt  # hide
```

## `seaborn!()`

```@example templates
preset.template.seaborn!()
plt  # hide
```

## `simple_white!()`

```@example templates
preset.template.simple_white!()
plt  # hide
```

## `xgridoff!()`

```@example templates
preset.template.xgridoff!()
plt  # hide
```

## `ygridoff!()`

```@example templates
preset.template.ygridoff!()
plt  # hide
```

## Custom Template

To create your own template, simply provide a `Config` (or any `AbstractDict`/`NamedTuple`) to `PlotlyLight.settings.layout.template`.  Here's an example:

```@example templates
my_template = Config()
my_template.layout.title.text = "This Title Will be in Every Plot!"

PlotlyLight.settings.layout.template = my_template

plt  # hide
```
