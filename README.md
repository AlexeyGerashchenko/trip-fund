# TripFund: сбор на поездку команды

Полное решение базового задания по Solidity и всех трёх бонусных пунктов V2.
Все проверки и демонстрация работают локально. RPC, кошелёк и реальные токены не нужны.

## Версии

| Компонент | Версия |
| --- | --- |
| Solidity | 0.8.30 |
| Foundry | 1.8.5 |
| OpenZeppelin Contracts | 5.4.0 |
| OpenZeppelin Contracts Upgradeable | 5.4.0 |
| OpenZeppelin Foundry Upgrades | 0.4.2 |
| OpenZeppelin Upgrades Core | 1.46.0 |
| forge-std | 1.9.7 |
| Node.js | 20 или новее; проверено с 26.5.0 |

Версии npm-зависимостей закреплены в `package.json` и `package-lock.json`.
`forge-std` включён в `lib/forge-std` вместе с исходными лицензиями: устанавливать
Git-подмодули не требуется. EVM настроен на Cancun, оптимизатор: 200 запусков.

## Запуск уже подготовленной локальной папки

Откройте терминал в папке `trip-fund`. В подготовленной папке для macOS ARM64
инструменты находятся в `.tools/bin`, а npm-зависимости уже установлены.

```bash
source scripts/env.sh
forge build
forge test
```

Одна команда для форматирования, чистой сборки и всех тестов:

```bash
npm run check
```

`scripts/env.sh` добавляет локальные инструменты в PATH и выбирает локальный
Solidity, если он присутствует. Конфигурация не содержит абсолютных путей
и не зависит от исходного расположения папки.

## Установка после переноса или клонирования

1. Установите Node.js 20+ и Foundry по официальной инструкции:
   <https://getfoundry.sh/introduction/installation>.
   Для той же версии Foundry выполните `foundryup -i v1.8.5`.
2. Перейдите в корень проекта и установите зависимости:

```bash
npm ci
forge build
forge test
```

При первой сборке Foundry загрузит Solidity 0.8.30. Интернет нужен для установки
инструментов, компилятора и npm-зависимостей. После установки тесты выполняются
без сети. В `npm run check` включён `npm_config_offline=true`: проверка обновления
использует установленный Upgrades Core, а не загружает новую версию через npx.

В Windows используйте WSL либо bash с настройкой `OPENZEPPELIN_BASH_PATH`
по документации OpenZeppelin. Автоматическая проверка GitHub Actions включена
в `.github/workflows/tests.yml` и будет работать после публикации репозитория.

## Структура

```text
src/
  TripFund.sol                  Обычный контракт с конструктором
  TripFundV1.sol                Реализация V1 для Transparent Proxy
  TripFundV2.sol                V2: contributeFor(beneficiary, amount)
  MockERC20.sol                 Локальный ERC-20 без комиссии и rebasing
  interfaces/ITripFund.sol      Общий интерфейс, ошибки и события
test/
  TripFund.behavior.t.sol       Одинаковые проверки обычного TripFund и прокси V1
  TripFund.upgrade.t.sol        Обновление V1 -> V2, права, вклады за друга
  mocks/FailingToken.sol        Имитация отказа токена для тестов отката
script/LocalDemo.s.sol          Локальная демонстрация полного сценария бонуса
scripts/check.sh                Полная проверка проекта
scripts/env.sh                  Подключение локальных инструментов
foundry.toml                    Настройки компилятора, тестов и Upgrades
remappings.txt                  Пути к библиотекам
VERIFICATION.md                 Результаты проверки готового проекта
```

## Основной контракт

```solidity
TripFund fund = new TripFund(token, organizer, goal, deadline);
```

`token` и `organizer` должны быть ненулевыми адресами, `goal > 0`,
`deadline > block.timestamp`. Цель и суммы выражены в минимальных единицах
токена, срок - в секундах Unix. У обычного TripFund эти параметры `immutable`;
функций их изменения нет.

- `contribute(amount)` принимает только `amount > 0` до дедлайна. Повторные
  взносы суммируются в `contributions(address)` и `totalRaised`.
- Начиная ровно с дедлайна, при `totalRaised >= goal` организатор один раз
  вызывает `withdraw()` и получает всю учтённую сумму, включая превышение цели.
- При `totalRaised < goal` каждый вкладчик самостоятельно вызывает `refund()`
  и получает свой полный вклад. Повторный возврат и возврат без вклада запрещены.
- До дедлайна выплаты запрещены, даже если цель уже достигнута.
- `totalRaised` хранит историческую сумму взносов и не уменьшается после выплат.
- Прямой `token.transfer(address(fund), amount)` не считается взносом,
  не приближает достижение цели и не распределяется. Такие токены остаются
  в контракте после всех положенных выплат; функции их извлечения нет.

Применяются `SafeERC20` и защита от повторного входа. Учёт и события обновляются
до вызова токена. При ошибке перевода вся транзакция, включая учёт и события,
откатывается. Перед возвратом вклад обнуляется; перед выводом устанавливается
`withdrawn = true`.

Поддерживается обычный ERC-20 без комиссии при переводах и автоматического
пересчёта балансов. `MockERC20` основан на OpenZeppelin ERC20, использует 18
десятичных знаков; его открытый `mint` предназначен только для локальных тестов.

## Пример approve и взноса

Вызовы выполняет вкладчик. Разрешение выдаётся у токена на адрес фонда:

```solidity
// Для MockERC20 10 ether означает 10 * 10^18 минимальных единиц TRIP.
uint256 amount = 10 ether;
token.approve(address(fund), amount);
fund.contribute(amount);
```

`ether` здесь используется как числовой множитель. ETH контракту не отправляется.
При вызовах через `cast` используйте `approve(address,uint256)` на адресе токена
и `contribute(uint256)` на адресе фонда, с одной и той же суммой в минимальных
единицах. Сначала должна успешно завершиться транзакция `approve`.

## Бонус: Transparent Proxy V1 -> V2

V1 создаётся сразу через OpenZeppelin Transparent Proxy 5.x. Параметры находятся
в storage прокси и задаются `initialize` в его конструкторе, одной транзакцией:

```solidity
address proxy = Upgrades.deployTransparentProxy(
    "TripFundV1.sol:TripFundV1",
    adminOwner,
    abi.encodeCall(TripFundV1.initialize, (token, organizer, goal, deadline))
);
```

`adminOwner` - владелец автоматически созданного `ProxyAdmin`, имеющий право
обновления. `organizer` - получатель выплаты успешного сбора. Это разные роли.
Инициализация реализаций V1 и V2 заблокирована через `_disableInitializers()`;
повторная инициализация прокси запрещена до и после обновления.

До дедлайна тот же прокси обновляется до V2. В тестах и локальном примере:

```solidity
Upgrades.upgradeProxy(proxy, "TripFundV2.sol:TripFundV2", "", adminOwner);
```

Последний аргумент выбирает вызывающего для локальной симуляции. Проверку прав
при этом выполняет настоящий `ProxyAdmin`. Эта перегрузка предназначена
для тестов и локальной демонстрации; для broadcast используют `--sender`
и обычную перегрузку по документации OpenZeppelin.

V2 наследует V1 без добавления или перестановки переменных хранения.
`@custom:oz-upgrades-from TripFundV1` и тест
`test_OpenZeppelinValidatedDeploymentAndUpgrade` запускают проверку безопасности
и совместимости storage через OpenZeppelin Upgrades. Обход проверок не используется.
Аннотация разрешения конструктора нужна только для `_disableInitializers()`.

Вклад за друга:

```solidity
token.approve(proxy, amount); // spender - прокси, а не реализация
TripFundV2(proxy).contributeFor(friend, amount);
```

Токены всегда списываются с `msg.sender`; вклад и право возврата получает
ненулевой `friend`. Взносы разных плательщиков за одного получателя суммируются.
Вызов за себя разрешён. Событие
`ContributedFor(payer, beneficiary, amount)` содержит все три значения.
Обычный `contribute` продолжает работать после обновления.

Для бонуса все обращения к фонду идут через один и тот же адрес прокси,
а `approve` всегда выдаётся токену с адресом прокси в качестве spender.

## Тесты и демонстрация

```bash
forge test -vv
forge test --match-contract TripFundTest
forge test --match-contract TripFundProxyV1Test
forge test --match-contract TripFundUpgradeTest
forge test --match-test test_OpenZeppelinValidatedDeploymentAndUpgrade -vv
forge script script/LocalDemo.s.sol:LocalDemo
```

`LocalDemo` выполняет локальную симуляцию: создаёт токен и прокси V1,
вносит 10 TRIP через `approve + contribute`, обновляет до V2 до дедлайна,
вносит 5 TRIP за друга, переводит время к дедлайну и возвращает вклады.
Друг получает 5 TRIP, плательщик - свои 10 TRIP; исторический `totalRaised`
остаётся равен 15 TRIP. Симуляция не отправляет транзакции во внешнюю сеть.

Полная проверка соответствует пунктам задания:

| Пункты | Что проверяется |
| --- | --- |
| 1 | Начальные параметры; нулевые адреса, цель, прошлый и текущий срок отклоняются |
| 2, 3, 6 | Два вкладчика, повторные взносы, balances, allowance, ошибки без изменения состояния |
| 4, 7, 8 | Дедлайн до секунды, цель ровно/выше/ниже, роли, полные выплаты и повторные вызовы |
| 5 | События, SafeERC20, откат вклада/флага при отказе токена, успешная повторная попытка |
| 9 | Прямые токены не меняют исход сбора и остаются после вывода либо всех возвратов |
| 10 | Transparent Proxy 5.x, initialize, блокировка реализаций, только владелец ProxyAdmin обновляет |
| 11 | contributeFor, ненулевой получатель, payer/beneficiary, суммы, allowance, дедлайн, событие |
| 12 | Проверка storage через Upgrades, тот же прокси и сохранённые данные, возврат другу, обычный взнос после обновления |

Fuzz-тесты дополнительно проверяют суммы взносов, сохранение балансов,
неучтённые переводы и право получателя подаренного взноса. Каждый запускается
256 раз. Для проверки обновления включены `ffi`, `ast`, `build_info`
и `storageLayout` в `foundry.toml`.

Предупреждения Foundry lint о `block.timestamp` относятся к проверкам срока,
которые прямо требуются заданием. Срок определяется временем блока.

## Перенос в GitHub

Загрузите исходники этой папки, включая `lib/forge-std`, `package-lock.json`,
тесты и настройки. `.gitignore` исключает локальные инструменты, npm-зависимости,
сборочные файлы и кеш. После клонирования достаточно установки Foundry/Node.js,
`npm ci`, `forge build` и `forge test`. Опубликовать папку можно как обычный
GitHub-репозиторий; ссылка на него является сдаваемым результатом задания.

## Материалы

- ERC-20 и SafeERC20: <https://docs.openzeppelin.com/contracts/5.x/api/token/erc20>
- Transparent Proxy и ProxyAdmin: <https://docs.openzeppelin.com/contracts/5.x/api/proxy>
- Foundry Upgrades: <https://docs.openzeppelin.com/upgrades-plugins/foundry/foundry-upgrades>
- Foundry: <https://getfoundry.sh/>
